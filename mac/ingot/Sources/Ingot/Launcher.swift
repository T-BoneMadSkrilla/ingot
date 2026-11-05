import AppKit
import Foundation
import SwiftUI

/// The settings games launch with (Settings window).
enum Pref {
    static let renderScale = "renderScale"
    static let audio = "audio"
    static let widescreen = "widescreen"
    static let hdModes = "hdModes"
    static let uncap = "uncap"
    static let fullscreen = "fullscreen"
    static let language = "language"
    static let hddPath = "hddPath"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [renderScale: 2, audio: true, language: 0])
    }

    static var defaultHDD: URL { Library.support.appendingPathComponent("HDD", isDirectory: true) }

    static var hdd: URL {
        let p = UserDefaults.standard.string(forKey: hddPath) ?? ""
        return p.isEmpty ? defaultHDD : URL(fileURLWithPath: p)
    }
}

@MainActor
final class Launcher: ObservableObject {
    static let shared = Launcher()

    @Published private(set) var running: Game?
    @Published var failure: Failure?
    private var process: Process?
    private var stopping = false

    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let log: URL
    }

    static let logDir: URL = {
        let u = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Ingot", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// The core: the player app inside Ingot.app, or INGOT_CORE (a build's
    /// xboxrun) when run outside a bundle.
    static var core: URL? {
        if let p = ProcessInfo.processInfo.environment["INGOT_CORE"] { return URL(fileURLWithPath: p) }
        let u = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/Ingot Player.app/Contents/MacOS/Ingot Player")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    func play(_ game: Game, fullscreen: Bool? = nil) {
        guard running == nil else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let core = Self.core else {
            failure = Failure(title: "Ingot's core is missing",
                              message: "Ingot Player wasn't found inside the app. Rebuild with mac/ingot/build.sh.",
                              log: Self.logDir)
            return
        }
        let d = UserDefaults.standard
        let hdd = Pref.hdd
        try? FileManager.default.createDirectory(at: hdd, withIntermediateDirectories: true)

        var args = [game.url.path, "hdd=\(hdd.path)"]
        let scale = d.integer(forKey: Pref.renderScale)
        if scale > 1 { args.append("scale=\(scale)") }
        if d.bool(forKey: Pref.uncap) { args.append("uncap") }
        // XC_VIDEO_FLAGS: widescreen 0x01, 720p 0x02, 1080i 0x04, 480p 0x08
        var video = 0
        if d.bool(forKey: Pref.widescreen) { video |= 0x01 }
        if d.bool(forKey: Pref.hdModes) { video |= 0x02 | 0x08 }
        if video != 0 {
            args.append("video=\(String(video, radix: 16))")
            if video & 0x0A != 0 { args.append("avpack=hdtv") }
        }
        let lang = d.integer(forKey: Pref.language)
        if lang > 0 { args.append("lang=\(lang)") }

        var env = ProcessInfo.processInfo.environment
        env["INGOT_TITLE"] = game.title
        if let icon = Bundle.main.url(forResource: "Ingot", withExtension: "icns") { env["INGOT_ICON"] = icon.path }
        if fullscreen ?? d.bool(forKey: Pref.fullscreen) { env["INGOT_FULLSCREEN"] = "1" }
        if d.bool(forKey: Pref.widescreen) { env["INGOT_WIDESCREEN"] = "1" }
        if !d.bool(forKey: Pref.audio) { env["NC_AUDIO"] = "0" }

        let safe = game.title.replacingOccurrences(of: "/", with: "-")
        let log = Self.logDir.appendingPathComponent("\(safe).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let out = try? FileHandle(forWritingTo: log)

        let p = Process()
        p.executableURL = core
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = hdd.deletingLastPathComponent()
        p.standardOutput = out
        p.standardError = out
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus, reason = proc.terminationReason
            Task { @MainActor in self?.ended(game, status: status, reason: reason, log: log) }
        }
        do {
            try p.run()
            process = p
            running = game
            stopping = false
        } catch {
            failure = Failure(title: "Couldn't start \(game.title)", message: error.localizedDescription, log: log)
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    private func ended(_ game: Game, status: Int32, reason: Process.TerminationReason, log: URL) {
        process = nil
        running = nil
        if stopping { return }
        let why: String?
        if reason == .uncaughtSignal {
            why = "The emulator crashed (signal \(status))."
        } else {
            switch status {
            case 0, 10: why = nil   // closed, or the game quit to the dashboard
            case 1: why = "The game couldn't boot."
            case 2: why = "The disc image couldn't be opened."
            case 3: why = "The emulator hit a fault it couldn't handle."
            case 6: why = "The game stopped responding."
            case 7: why = "The game stopped on an error."
            case 8: why = "The save state couldn't be loaded."
            default: why = "The emulator exited with code \(status)."
            }
        }
        if let why {
            failure = Failure(title: "\(game.title) stopped", message: why, log: log)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
