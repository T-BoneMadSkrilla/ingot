import AppKit
import SwiftUI

/// Disc images opened from Finder ("Open With", or dropped on the icon) play.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in
            Launcher.shared.play(Game(url: url, info: Disc.read(url)?.0))
        }
    }
}

@main
struct IngotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library: Library
    @StateObject private var launcher = Launcher.shared

    init() {
        Pref.registerDefaults()
        _library = StateObject(wrappedValue: Library())
    }

    var body: some Scene {
        Window("Ingot", id: "library") {
            LibraryView()
                .environmentObject(library)
                .environmentObject(launcher)
                .tint(Color(red: 0.36, green: 0.78, blue: 0.29))
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Ingot") { showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Game Folder…") { chooseFolder(library) }.keyboardShortcut("o")
                Button("Rescan Library") { library.rescan() }.keyboardShortcut("r")
            }
            CommandMenu("Game") {
                Button("Stop Game") { launcher.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(launcher.running == nil)
                Divider()
                Button("Show Logs") { NSWorkspace.shared.open(Launcher.logDir) }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(library)
        }
    }

    private func showAbout() {
        let credits = NSMutableAttributedString(string:
            "Original Xbox emulation for Apple silicon, drawn with Metal.\n\n"
            + "Ingot is a fork of hakuX by rfandango (github.com/rfandango/hakuX), "
            + "with its FEX-based JIT, Xbox kernel and NV2A renderer. Audio is the MCPX APU ported from xemu.\n\n"
            + "Free software under the GNU General Public License, version 3 or later.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Ingot"])
        NSApp.activate(ignoringOtherApps: true)
    }
}
