import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var launcher: Launcher
    @AppStorage("layout") private var layout = "grid"
    @AppStorage("tileSize") private var tileSize = 170.0
    @State private var search = ""
    @State private var selection: Game.ID?

    private var shown: [Game] {
        search.isEmpty ? library.games : library.games.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
    private var selected: Game? { library.games.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if library.games.isEmpty {
                EmptyLibrary()
            } else if layout == "grid" {
                grid
            } else {
                list
            }
            if let game = launcher.running {
                NowPlaying(game: game)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .searchable(text: $search, placement: .toolbar, prompt: "Search games")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    if let g = selected { launcher.play(g) }
                } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(selected == nil || launcher.running != nil)
                    .help("Play the selected game")
                if launcher.running != nil {
                    Button { launcher.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop the running game")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if layout == "grid" {
                    Slider(value: $tileSize, in: 120...280).frame(width: 90).help("Cover size")
                }
                Picker("Layout", selection: $layout) {
                    Image(systemName: "square.grid.2x2").tag("grid")
                    Image(systemName: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                .help("Grid or list")
                Button { library.rescan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(library.scanning)
                    .help("Rescan game folders")
                Button { chooseFolder(library) } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                    .help("Add a folder of games")
            }
        }
        .navigationTitle("Ingot")
        .navigationSubtitle(library.scanning ? "Scanning…" : "\(library.games.count) games")
        .alert(item: $launcher.failure) { f in
            Alert(title: Text(f.title), message: Text(f.message),
                  primaryButton: .default(Text("Show Log")) { NSWorkspace.shared.activateFileViewerSelecting([f.log]) },
                  secondaryButton: .cancel(Text("OK")))
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.25), spacing: 20)],
                      spacing: 24) {
                ForEach(shown) { game in
                    GameCard(game: game, cover: library.covers[game.url], size: tileSize,
                             selected: selection == game.id, playing: launcher.running?.id == game.id)
                        .onTapGesture(count: 2) { launcher.play(game) }
                        .simultaneousGesture(TapGesture().onEnded { selection = game.id })
                        .contextMenu { GameMenu(game: game) }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onTapGesture { selection = nil }
    }

    private var list: some View {
        Table(shown, selection: $selection) {
            TableColumn("") { g in
                CoverImage(game: g, cover: library.covers[g.url]).frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .width(36)
            TableColumn("Title", value: \.title)
            TableColumn("Title ID") { g in Text(g.titleIDText).monospaced().foregroundStyle(.secondary) }
                .width(90)
            TableColumn("Region") { g in Text(g.regionText).foregroundStyle(.secondary) }.width(90)
            TableColumn("Size") { g in Text(g.sizeText).foregroundStyle(.secondary) }.width(80)
            TableColumn("File") { g in Text(g.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1) }
        }
        .contextMenu(forSelectionType: Game.ID.self) { ids in
            if let id = ids.first, let g = library.games.first(where: { $0.id == id }) { GameMenu(game: g) }
        } primaryAction: { ids in
            if let id = ids.first, let g = library.games.first(where: { $0.id == id }) { launcher.play(g) }
        }
    }
}

struct GameMenu: View {
    let game: Game
    @EnvironmentObject var library: Library
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        Button("Play") { launcher.play(game) }.disabled(launcher.running != nil)
        Button("Play Full Screen") { launcher.play(game, fullscreen: true) }.disabled(launcher.running != nil)
        Divider()
        Button("Set Cover Art…") {
            let p = NSOpenPanel()
            p.allowedContentTypes = [.image]
            p.message = "Choose cover art for \(game.title)"
            if p.runModal() == .OK, let u = p.url { library.setCover(u, for: game) }
        }
        Button("Use Disc's Title Image") { library.clearCover(for: game) }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
        Button("Copy Title ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(game.titleIDText, forType: .string)
        }
        .disabled(game.info == nil)
    }
}

struct GameCard: View {
    let game: Game
    let cover: NSImage?
    let size: Double
    let selected: Bool
    let playing: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 8) {
            CoverImage(game: game, cover: cover)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .white.opacity(0.08), lineWidth: selected ? 3 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if playing {
                        Label("Playing", systemImage: "play.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.green, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .shadow(color: .black.opacity(hover ? 0.35 : 0.2), radius: hover ? 10 : 5, y: hover ? 5 : 2)
                .scaleEffect(hover ? 1.03 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
            Text(game.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: size)
        }
        .onHover { hover = $0 }
        .help(game.url.lastPathComponent)
    }
}

/// The cover, else a metal plate with the title on it.
struct CoverImage: View {
    let game: Game
    let cover: NSImage?

    var body: some View {
        if let cover {
            Image(nsImage: cover).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            GeometryReader { geo in
                ZStack {
                    LinearGradient(colors: [Color(white: 0.42), Color(white: 0.18)], startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                    LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
                    Text(game.title)
                        .font(.system(size: max(10, geo.size.width / 9), weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .padding(geo.size.width / 10)
                }
            }
        }
    }
}

struct NowPlaying: View {
    let game: Game
    @EnvironmentObject var launcher: Launcher

    var body: some View {
        HStack {
            Image(systemName: "gamecontroller.fill").foregroundStyle(.green)
            Text("Playing **\(game.title)**")
            Spacer()
            Button("Stop") { launcher.stop() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}

struct EmptyLibrary: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text("No games yet").font(.title2.bold())
            Text("Ingot looks for .iso and .xiso disc images in your game folders.\n"
                 + "Currently: \(library.folders.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", "))")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add Game Folder…") { chooseFolder(library) }.controlSize(.large).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

@MainActor
func chooseFolder(_ library: Library) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.allowsMultipleSelection = false
    p.message = "Choose a folder with Xbox disc images"
    if p.runModal() == .OK, let u = p.url { library.addFolder(u) }
}
