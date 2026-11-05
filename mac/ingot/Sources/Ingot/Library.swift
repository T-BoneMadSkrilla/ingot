import AppKit
import Foundation
import SwiftUI

struct Game: Identifiable, Hashable {
    let url: URL
    var info: DiscInfo?
    var id: URL { url }

    var title: String {
        if let t = info?.title, !t.isEmpty { return t }
        return Game.cleanName(url)
    }
    var titleIDText: String { info.map { String(format: "%08X", $0.titleID) } ?? "—" }
    var regionText: String {
        guard let r = info?.region else { return "—" }
        var parts: [String] = []
        if r & 1 != 0 { parts.append("NA") }
        if r & 2 != 0 { parts.append("JP") }
        if r & 4 != 0 { parts.append("EU") }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
    var sizeText: String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// "Halo 2 (USA, Europe) (En,Ja).xiso.iso" → "Halo 2"
    static func cleanName(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".xiso") { name = String(name.dropLast(5)) }
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        return name.trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published private(set) var scanning = false
    @Published private(set) var covers: [URL: NSImage] = [:]
    @AppStorage("folders") private var foldersData: Data = Data()

    nonisolated static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ingot", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    nonisolated private static let coverDir = support.appendingPathComponent("Covers", isDirectory: true)
    nonisolated private static let iconDir = support.appendingPathComponent("Title Images", isDirectory: true)
    nonisolated private static let cacheURL = support.appendingPathComponent("library.json")

    private struct CacheEntry: Codable {
        var size: Int
        var modified: Date
        var info: DiscInfo?
    }
    private var cache: [String: CacheEntry] = [:]

    var folders: [URL] {
        get {
            let paths = (try? JSONDecoder().decode([String].self, from: foldersData)) ?? []
            if paths.isEmpty {
                return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/xbox")]
            }
            return paths.map { URL(fileURLWithPath: $0) }
        }
        set {
            foldersData = (try? JSONEncoder().encode(newValue.map(\.path))) ?? Data()
            objectWillChange.send()
            rescan()
        }
    }

    init() {
        for d in [Self.coverDir, Self.iconDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        if let d = try? Data(contentsOf: Self.cacheURL),
           let c = try? JSONDecoder().decode([String: CacheEntry].self, from: d) {
            cache = c
        }
        rescan()
    }

    func addFolder(_ url: URL) {
        var f = folders
        if !f.contains(url) { f.append(url) }
        folders = f
    }

    func removeFolder(_ url: URL) {
        folders = folders.filter { $0 != url }
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        let folders = self.folders
        let cache = self.cache
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var urls: [URL] = []
            for folder in folders {
                guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let u as URL in e.allObjects where ["iso", "xiso"].contains(u.pathExtension.lowercased()) {
                    urls.append(u)
                }
            }
            var games: [Game] = []
            var newCache: [String: CacheEntry] = [:]
            var icons: [URL: NSImage] = [:]
            for u in urls {
                let rv = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = rv?.fileSize ?? 0, modified = rv?.contentModificationDate ?? .distantPast
                let iconURL = Library.iconURL(for: u)
                if let c = cache[u.path], c.size == size, c.modified == modified {
                    newCache[u.path] = c
                    games.append(Game(url: u, info: c.info))
                } else {
                    let read = Disc.read(u)
                    if let img = read?.1, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: iconURL)
                    }
                    newCache[u.path] = CacheEntry(size: size, modified: modified, info: read?.0)
                    games.append(Game(url: u, info: read?.0))
                }
                if let img = Library.loadCover(for: u) { icons[u] = img }
            }
            games.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let result = games, resultCache = newCache
            nonisolated(unsafe) let resultIcons = icons
            await MainActor.run {
                self.games = result
                self.cache = resultCache
                self.covers = resultIcons
                self.scanning = false
                if let d = try? JSONEncoder().encode(resultCache) { try? d.write(to: Self.cacheURL) }
            }
        }
    }

    // MARK: covers

    nonisolated private static func stableKey(_ u: URL) -> String {
        // FNV-1a of the path: stable across launches, unlike hashValue.
        var h: UInt64 = 0xcbf29ce484222325
        for b in u.path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
    nonisolated static func iconURL(for u: URL) -> URL { iconDir.appendingPathComponent(stableKey(u) + ".png") }
    nonisolated static func customCoverURL(for u: URL) -> URL { coverDir.appendingPathComponent(stableKey(u) + ".png") }

    /// A cover the user chose, else the disc's own title image.
    nonisolated static func loadCover(for u: URL) -> NSImage? {
        NSImage(contentsOf: customCoverURL(for: u)) ?? NSImage(contentsOf: iconURL(for: u))
    }

    func setCover(_ image: URL, for game: Game) {
        guard let img = NSImage(contentsOf: image), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: Self.customCoverURL(for: game.url))
        covers[game.url] = NSImage(contentsOf: Self.customCoverURL(for: game.url))
    }

    func clearCover(for game: Game) {
        try? FileManager.default.removeItem(at: Self.customCoverURL(for: game.url))
        covers[game.url] = Self.loadCover(for: game.url)
    }
}
