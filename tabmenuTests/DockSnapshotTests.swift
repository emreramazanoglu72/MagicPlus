//
//  DockSnapshotTests.swift
//  tabmenuTests
//

import Testing
import AppKit
import SwiftUI
@testable import tabmenu

/// Renders the strip to PNGs so its design can be looked at rather than imagined.
///
/// Disabled by default, like the island's: it writes files and is a design aid, not an assertion
/// about behaviour. Run it with `DOCK_SNAPSHOTS=1` and the images land in `DOCK_SNAPSHOT_DIR` (or
/// the temporary directory).
///
/// It draws over a photograph-ish gradient rather than a flat grey, deliberately. The strip is
/// glass: on a flat background every judgement about it is wrong, because the one thing glass does
/// is take its colour from whatever is behind it.
@Suite("Dock snapshots", .enabled(if: ProcessInfo.processInfo.environment["DOCK_SNAPSHOTS"] == "1"))
struct DockSnapshotTests {
    private var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["DOCK_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Applications that exist on any Mac, so the icons and the colours read off them are real.
    /// Safari is the exception: it lives in `/Applications`, not `/System/Applications`.
    private let applications = [
        "/Applications/Safari.app",
        "/System/Applications/Mail.app",
        "/System/Applications/Music.app",
        "/System/Applications/Messages.app",
        "/System/Applications/Notes.app",
        "/System/Applications/Calendar.app",
        "/System/Applications/Maps.app",
        "/System/Applications/System Settings.app"
    ]

    @MainActor
    private func makeModel(frontmost frontmostPath: String) -> DockModel {
        let model = DockModel()

        model.tiles = applications.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return DockTile(
                id: "snapshot.\(path)",
                kind: .application(bundleIdentifier: Bundle(url: url)?.bundleIdentifier),
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                isRunning: true
            )
        }
        model.tiles.append(
            DockTile(id: "snapshot.trash", kind: .trash, url: nil, name: "Trash")
        )

        let front = URL(fileURLWithPath: frontmostPath)
        model.frontmostName = front.deletingPathExtension().lastPathComponent
        model.frontmostIcon = NSWorkspace.shared.icon(forFile: frontmostPath)
        model.frontmostBundleIdentifier = Bundle(url: front)?.bundleIdentifier ?? frontmostPath
        model.frontmostWindowTitle = "DockStripView.swift — MagicPlus"
        model.badges = [
            Bundle(url: URL(fileURLWithPath: "/System/Applications/Mail.app"))?.bundleIdentifier ?? "": "12",
            Bundle(url: URL(fileURLWithPath: "/System/Applications/Messages.app"))?.bundleIdentifier ?? "": "3"
        ]
        return model
    }

    @MainActor
    private func strip(_ model: DockModel) -> some View {
        DockStripView(
            model: model,
            onStart: { _ in },
            onOpenTile: { _, _ in },
            onMedia: { _ in },
            onVolume: { _ in },
            onSetEdge: { _ in },
            onOpenSettings: {},
            onDisable: {},
            onHoverIcon: { _ in },
            onDrop: { _, _ in false },
            onShowDesktop: {},
            onDropOnAgent: { _ in false },
            onHoverStrip: { _ in },
            onAgent: { _ in },
            menu: { tile, _ in DockTileMenu.empty(for: tile) }
        )
    }

    /// Something with colour in it, so the glass has something to pick up.
    private var wallpaper: some View {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.13, blue: 0.28),
                Color(red: 0.42, green: 0.20, blue: 0.42),
                Color(red: 0.86, green: 0.45, blue: 0.30)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @MainActor
    private func write(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        scheme: ColorScheme = .dark,
        named name: String
    ) throws {
        let renderer = ImageRenderer(
            content: ZStack(alignment: .bottom) {
                wallpaper
                view.frame(width: width, height: height)
            }
            .frame(width: width, height: height + 80)
            .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            Issue.record("could not render \(name)")
            return
        }
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    /// The panel behind the first button, at the size it actually opens at.
    @MainActor
    @Test func rendersTheStartMenu() throws {
        let model = StartMenuPanel.Model()
        model.apps = AppLauncher.installedApps()
        model.selection = 3

        try write(
            StartMenuView(model: model, onLaunch: { _ in }, onSession: { _ in }),
            width: 600, height: 620, named: "start-menu"
        )

        model.query = "safar"
        try write(
            StartMenuView(model: model, onLaunch: { _ in }, onSession: { _ in }),
            width: 600, height: 620, named: "start-menu-search"
        )

        model.query = "zzzz"
        try write(
            StartMenuView(model: model, onLaunch: { _ in }, onSession: { _ in }),
            width: 600, height: 620, named: "start-menu-empty"
        )
    }

    /// The tiles, laid out by hand.
    ///
    /// `ImageRenderer` draws nothing at all for a `LazyVGrid` — it has no scroll geometry to lay
    /// itself out against — so the grid inside the panel comes out blank. Six tiles in a plain
    /// `Grid` is the same view under the same styling, and it is the part with the design in it.
    @MainActor
    @Test func rendersTheStartMenuTiles() throws {
        let apps = Array(AppLauncher.installedApps().prefix(12))
        guard !apps.isEmpty else { return }

        let sample = Grid(horizontalSpacing: 6, verticalSpacing: 4) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<6, id: \.self) { column in
                        let index = row * 6 + column
                        if apps.indices.contains(index) {
                            StartMenuTile(
                                app: apps[index],
                                isSelected: index == 3,
                                onOpen: {},
                                onHover: {}
                            )
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(white: 0.13))

        try write(sample, width: 600, height: 210, named: "start-menu-tiles")
    }

    @MainActor
    @Test func rendersTheStrip() throws {
        let width: CGFloat = 1400

        let idle = makeModel(frontmost: "/Applications/Safari.app")
        try write(strip(idle), width: width, height: idle.style.barHeight, named: "dock-strip-idle")

        idle.nowPlaying = NowPlaying(
            source: .app(.spotify),
            title: "Weightless",
            artist: "Marconi Union",
            album: "Ambient Transmissions",
            isPlaying: true,
            artworkURL: nil,
            position: 74,
            duration: 190
        )
        try write(strip(idle), width: width, height: idle.style.barHeight, named: "dock-strip-playing")

        // A different application in front, to show the wash changing colour with it.
        let music = makeModel(frontmost: "/System/Applications/Music.app")
        music.frontmostWindowTitle = "Ambient Transmissions"
        try write(strip(music), width: width, height: music.style.barHeight, named: "dock-strip-music")

        let settings = makeModel(frontmost: "/System/Applications/System Settings.app")
        settings.frontmostWindowTitle = "Displays"
        try write(strip(settings), width: width, height: settings.style.barHeight, named: "dock-strip-settings")

        // The strip has to hold up in both appearances, and the material behind it flips with them.
        try write(
            strip(idle), width: width, height: idle.style.barHeight,
            scheme: .light, named: "dock-strip-light"
        )
    }
}
