//
//  PaneHeightTests.swift
//  tabmenuTests
//

import Testing
import AppKit
import SwiftUI
@testable import tabmenu

/// The island's one hard layout rule, measured rather than trusted.
///
/// Every pane occupies the same height so the panel never resizes under the pointer — and so
/// nothing overflows onto the tab rail above it, which is what makes the other tabs unclickable
/// when it happens. A background that grew past its pane once already did exactly that.
@MainActor
@Suite("Pane heights")
struct PaneHeightTests {
    /// `NotchPanelContent` needs a namespace, which only a view can hold.
    private struct Probe: View {
        let model: NotchModel
        @Namespace private var morph

        var body: some View {
            // Mirrors what the island puts around it, so the measurement is of the thing the
            // window controller has to know the size of.
            NotchPanelContent(model: model, morph: morph)
                .padding(.bottom, Island.Space.l)
                .frame(width: NotchIslandView.expandedWidthValue - Island.Space.l * 2)
        }
    }

    private func makeModel() -> NotchModel {
        let defaults = UserDefaults(suiteName: "pane.heights") ?? .standard
        defaults.removePersistentDomain(forName: "pane.heights")
        let preferences = Preferences(defaults: defaults)
        let storage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("panes-\(UUID().uuidString).json")
        return NotchModel(
            shelf: ShelfStore(),
            downloads: DownloadStore(preferences: preferences, storageURL: storage),
            calendar: CalendarService(),
            mixer: AudioMixerService(preferences: preferences),
            brightness: DisplayBrightnessService(),
            preferences: preferences
        )
    }

    private func measure(_ tab: NotchTab, in model: NotchModel) -> CGFloat {
        model.selectedTab = tab
        let host = NSHostingView(rootView: Probe(model: model))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test func everyPaneMeasuresTheSame() {
        let model = makeModel()
        let heights = NotchTab.allCases.map { ($0, measure($0, in: model)) }

        let media = heights.first { $0.0 == .media }?.1 ?? 0
        for (tab, height) in heights {
            #expect(
                abs(height - media) < 1,
                "\(tab.rawValue) is \(height)pt where media is \(media)pt"
            )
        }
    }

    /// And the whole panel has to be the height the window controller assumes, or the pointer is
    /// captured over the wrong region and clicks land nowhere.
    @Test func thePanelIsTheHeightTheControllerExpects() {
        let model = makeModel()
        let measured = measure(.media, in: model)
        #expect(
            abs(measured - NotchIslandView.panelContentHeight) < 2,
            "panel measures \(measured)pt, controller assumes \(NotchIslandView.panelContentHeight)pt"
        )
    }
}
