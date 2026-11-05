import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            GraphicsSettings().tabItem { Label("Graphics", systemImage: "display") }
            AudioSettings().tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            ControlsSettings().tabItem { Label("Controls", systemImage: "gamecontroller") }
            SystemSettings().tabItem { Label("System", systemImage: "cpu") }
        }
        .frame(width: 540, height: 520)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var library: Library
    @AppStorage(Pref.hddPath) private var hddPath = ""
    @State private var picked: URL?

    var body: some View {
        Form {
            Section("Game folders") {
                List(selection: $picked) {
                    ForEach(library.folders, id: \.self) { f in
                        Label(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                            .tag(f)
                    }
                }
                .frame(height: 110)
                HStack {
                    Button("Add…") { chooseFolder(library) }
                    Button("Remove") { if let p = picked { library.removeFolder(p) } }.disabled(picked == nil)
                    Spacer()
                    Button("Rescan") { library.rescan() }
                }
            }
            Section("Hard disk") {
                LabeledContent("Folder") {
                    Text(Pref.hdd.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        p.canCreateDirectories = true
                        p.message = "Choose the folder that holds the Xbox hard disk (saves, profiles, caches)"
                        if p.runModal() == .OK, let u = p.url { hddPath = u.path }
                    }
                    Button("Use Default") { hddPath = "" }.disabled(hddPath.isEmpty)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: Pref.hdd, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([Pref.hdd])
                    }
                }
                Text("Saves, profiles and game caches live here, shared by every game, as on the console.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct GraphicsSettings: View {
    @AppStorage(Pref.renderScale) private var scale = 2
    @AppStorage(Pref.widescreen) private var widescreen = false
    @AppStorage(Pref.hdModes) private var hdModes = false
    @AppStorage(Pref.uncap) private var uncap = false
    @AppStorage(Pref.fullscreen) private var fullscreen = false

    var body: some View {
        Form {
            Picker("Resolution", selection: $scale) {
                Text("Native (640×480)").tag(1)
                Text("2× (1280×960)").tag(2)
                Text("3× (1920×1440)").tag(3)
                Text("4× (2560×1920)").tag(4)
            }
            Toggle("Widescreen (16:9)", isOn: $widescreen)
            Toggle("Allow HD modes (480p, 720p)", isOn: $hdModes)
            Toggle("Unlock frame rate", isOn: $uncap)
            Toggle("Start games in full screen", isOn: $fullscreen)
            Text("Widescreen and HD modes are what the console tells the game it may use; games that don't support them ignore them. Changes apply the next time a game starts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct AudioSettings: View {
    @AppStorage(Pref.audio) private var audio = true

    var body: some View {
        Form {
            Toggle("Sound", isOn: $audio)
            Text("Plays through the Mac's current output device.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct ControlsSettings: View {
    private let keys: [(String, String)] = [
        ("Left stick", "W A S D"), ("Right stick", "Arrow keys"),
        ("A  B  X  Y", "J  K  U  I"), ("White  Black", "H  L"),
        ("Left / right trigger", "Q  E"), ("D-pad", "1 2 3 4 (up, down, left, right)"),
        ("Start  Back", "Return  Delete"), ("Stick clicks", "Z  C"),
        ("Full screen", "⌃⌘F"), ("Quit game", "⌘Q"),
    ]

    var body: some View {
        Form {
            Section("Controller") {
                Text("Player 1 is the first connected game controller (Xbox, PlayStation, or any MFi controller). Its shoulder buttons are White and Black.")
                    .foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                ForEach(keys, id: \.0) { k in
                    LabeledContent(k.0) { Text(k.1).monospaced() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SystemSettings: View {
    @AppStorage(Pref.language) private var language = 0
    private let languages = ["Console's setting", "English", "Japanese", "German", "French", "Spanish", "Italian",
                             "Korean", "Chinese", "Portuguese"]

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                ForEach(languages.indices, id: \.self) { i in Text(languages[i]).tag(i) }
            }
        }
        .formStyle(.grouped)
    }
}
