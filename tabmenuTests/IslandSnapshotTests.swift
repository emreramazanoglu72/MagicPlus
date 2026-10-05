//
//  IslandSnapshotTests.swift
//  tabmenuTests
//

import Testing
import AppKit
import SwiftUI
@testable import tabmenu

/// Renders the island to PNGs so its three stages can be looked at rather than imagined.
///
/// Disabled by default: it writes files and is a design aid, not an assertion about
/// behaviour. Run it with `TEST_RUNNER_ISLAND_SNAPSHOTS=1` and the images land in
/// `TEST_RUNNER_ISLAND_SNAPSHOT_DIR` (or the temporary directory).
///
/// One thing to know before reading the output: `ImageRenderer` paints the frame of a view
/// carrying `.dropDestination` in an undefined yellow. It shows up around the island's
/// corners in every shot and does not exist in the running app — probing a bare shape, the
/// shape with the island's surface, and the same again with a drop destination puts the
/// yellow only on the third.
@Suite("Island snapshots", .enabled(if: ProcessInfo.processInfo.environment["ISLAND_SNAPSHOTS"] == "1"))
struct IslandSnapshotTests {
    private var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["ISLAND_SNAPSHOT_DIR"]
            ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A notch the size of the one on a 14" MacBook Pro.
    private let anchor = CGSize(width: 190, height: 32)

    @MainActor
    private func makeModel() -> NotchModel {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "island.snapshots") ?? .standard)
        return NotchModel(
            shelf: ShelfStore(),
            downloads: DownloadStore(preferences: preferences),
            calendar: CalendarService(),
            mixer: AudioMixerService(preferences: preferences),
            brightness: DisplayBrightnessService(),
            preferences: preferences
        )
    }

    @MainActor
    private func write(_ view: some View, size: CGSize, named name: String) throws {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.16))
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

    @MainActor
    @Test func rendersEveryStage() throws {
        let model = makeModel()

        try write(
            NotchIslandView(model: model, anchorSize: anchor),
            size: CGSize(width: 700, height: 90),
            named: "island-idle"
        )

        model.present(.nowPlaying(
            NowPlaying(
                source: .app(.spotify),
                title: "Weightless",
                artist: "Marconi Union",
                album: "Ambient Transmissions",
                isPlaying: true,
                artworkURL: nil,
                position: 74,
                duration: 190
            )
        ))
        try write(
            NotchIslandView(model: model, anchorSize: anchor),
            size: CGSize(width: 700, height: 90),
            named: "island-activity-media"
        )

        model.present(.volume(0.4))
        try write(
            NotchIslandView(model: model, anchorSize: anchor),
            size: CGSize(width: 700, height: 90),
            named: "island-activity-volume"
        )

        model.present(.lowBattery(9))
        try write(
            NotchIslandView(model: model, anchorSize: anchor),
            size: CGSize(width: 700, height: 90),
            named: "island-activity-alert"
        )

        model.presentOffer(DownloadOffer(candidate: DownloadCandidate(
            url: URL(string: "https://www.youtube.com/watch?v=abc")!,
            fileName: "youtube.com",
            kind: .video,
            byteSize: 14_400_000,
            isResumable: false,
            transport: .http,
            title: "I am Napoleon. I am Emperor x Rammstein — Sonne (slowed)",
            streamOptions: [
                StreamOption(id: "1", label: "1080p · 9,9 MB", url: URL(string: "https://x.dev/v")!,
                             audioURL: URL(string: "https://x.dev/a")!, byteSize: 14_400_000,
                             fileExtension: "mp4"),
                StreamOption(id: "2", label: "720p · 3,3 MB", url: URL(string: "https://x.dev/v2")!,
                             audioURL: URL(string: "https://x.dev/a")!, byteSize: 7_300_000,
                             fileExtension: "mp4")
            ]
        )))
        try write(
            NotchIslandView(model: model, anchorSize: anchor),
            size: CGSize(width: 700, height: 120),
            named: "island-offer-capsule"
        )
        model.setHovering(true)
        try write(
            NotchIslandView(model: model, anchorSize: anchor),
            size: CGSize(width: 700, height: 240),
            named: "island-offer-card"
        )
        model.setHovering(false)
        model.declineOffer()

        for tab in NotchTab.allCases {
            model.setHovering(true)
            model.selectedTab = tab
            try write(
                NotchIslandView(model: model, anchorSize: anchor),
                size: CGSize(width: 700, height: 320),
                named: "island-expanded-\(tab.rawValue)"
            )
        }
    }

    /// `ImageRenderer` draws nothing at all for content inside a `ScrollView`, which leaves
    /// the agenda and mixer panes blank in the shots above. They are rendered here without
    /// that wrapper so their contents can still be looked at.
    @MainActor
    @Test func rendersScrollingPaneContents() throws {
        let model = makeModel()
        let paneSize = CGSize(width: 468, height: Island.paneHeight)

        try write(
            MixerPane(mixer: model.mixer, brightness: model.brightness)
                .padding(Island.Space.l)
                .background(.black),
            size: CGSize(width: paneSize.width + 32, height: paneSize.height + 32),
            named: "pane-mixer"
        )

        try write(
            IslandEmptyState(
                systemImage: "calendar.badge.clock",
                title: "Calendar access is off",
                message: "Allow it and your next meetings appear here, with a button to join them."
            ) {
                IslandChipButton(title: "Allow", isProminent: true) {}
            }
            .frame(height: Island.paneHeight)
            .padding(Island.Space.l)
            .background(.black),
            size: CGSize(width: paneSize.width + 32, height: paneSize.height + 32),
            named: "pane-empty-state"
        )
    }
}
