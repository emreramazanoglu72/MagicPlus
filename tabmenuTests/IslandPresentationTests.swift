//
//  IslandPresentationTests.swift
//  tabmenuTests
//

import Testing
import AppKit
import Foundation
@testable import tabmenu

/// The island's activities all render through one presentation, which is what keeps thirteen
/// different events looking like one product. These pin the contract that makes that true.
@Suite("Island activity presentation")
struct IslandPresentationTests {
    private let track = NowPlaying(
        source: .system,
        title: "Song",
        artist: "Artist",
        album: "Album",
        isPlaying: true,
        artworkURL: nil,
        position: 30,
        duration: 180
    )

    private var event: AgendaEvent {
        AgendaEvent(
            id: "1",
            title: "Standup",
            startDate: Date().addingTimeInterval(300),
            endDate: Date().addingTimeInterval(900),
            location: nil,
            meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            calendarColor: .blue
        )
    }

    private var everyActivity: [NotchActivity] {
        [
            .nowPlaying(track),
            .volume(0.4),
            .meeting(event),
            .filesAdded(3),
            .screenshot(URL(fileURLWithPath: "/tmp/shot.png")),
            .download(name: "report.pdf"),
            .downloadStarted(name: "installer.dmg"),
            .downloadFailed(name: "installer.dmg"),
            .micStatus(muted: true),
            .micStatus(muted: false),
            .textCaptured(120),
            .lowBattery(9),
            .diskFull(freeBytes: 1_200_000_000),
            .windowsRescued(2),
            .sleepDespiteKeepAwake,
            .power(isCharging: true, percentage: 80),
            .power(isCharging: false, percentage: 64)
        ]
    }

    /// An activity with no headline would show an empty capsule, which is worse than not
    /// showing one at all.
    @Test func everyActivityHasSomethingToSay() {
        for activity in everyActivity {
            #expect(!activity.presentation.title.isEmpty, "\(activity.kindIdentifier) has no title")
        }
    }

    /// Detail lines are optional, but an empty string is not the same as absent: it would
    /// reserve a line and draw nothing in it.
    @Test func detailIsEitherAbsentOrRealText() {
        for activity in everyActivity {
            if let detail = activity.presentation.detail {
                #expect(!detail.isEmpty, "\(activity.kindIdentifier) has an empty detail line")
            }
        }
    }

    /// Only values get a meter; events are not 40% of anything.
    @Test func onlyValuesCarryAMeter() {
        #expect(NotchActivity.volume(0.4).presentation.meter == 0.4)
        #expect(NotchActivity.filesAdded(1).presentation.meter == nil)
        #expect(NotchActivity.nowPlaying(track).presentation.meter == nil)
    }

    /// The badge is the affordance for the one activity that can be acted on. A meeting with no
    /// link must not offer to join it.
    @Test func onlyAJoinableMeetingGetsABadge() {
        #expect(NotchActivity.meeting(event).presentation.badge != nil)
        #expect(NotchActivity.downloadStarted(name: "x.zip").presentation.badge == nil)

        let linkless = AgendaEvent(
            id: "2",
            title: "Desk time",
            startDate: Date(),
            endDate: Date().addingTimeInterval(600),
            location: nil,
            meetingURL: nil,
            calendarColor: .blue
        )
        #expect(NotchActivity.meeting(linkless).presentation.badge == nil)
        #expect(NotchActivity.volume(0.5).presentation.badge == nil)
    }

    /// The waveform is a playback indicator, not an ornament.
    @Test func onlyPlaybackAnimates() {
        #expect(NotchActivity.nowPlaying(track).presentation.showsWaveform)
        for activity in everyActivity where activity.kindIdentifier != "nowPlaying" {
            #expect(!activity.presentation.showsWaveform, "\(activity.kindIdentifier) should not animate")
        }
    }

    /// Warnings are allowed to colour their headline; nothing else is, or the capsule turns
    /// into a paint chart.
    @Test func onlyWarningsColourTheirHeadline() {
        let alerting = everyActivity.filter { $0.presentation.isAlert }.map(\.kindIdentifier)
        #expect(Set(alerting) == [
            "micStatus", "lowBattery", "diskFull", "sleepDespiteKeepAwake", "downloadFailed"
        ])
    }

    /// Each activity has to fit the capsule it asks for: the window controller mirrors these
    /// widths for click hit-testing.
    @Test func everyActivityAsksForRoom() {
        for activity in everyActivity {
            #expect(activity.sideWidth >= 60, "\(activity.kindIdentifier) is too narrow to read")
            #expect(activity.sideWidth <= 120, "\(activity.kindIdentifier) would overrun the notch")
        }
    }
}

@Suite("Island design tokens")
struct IslandTokenTests {
    /// Panes are pinned to one height so the panel never resizes under the pointer.
    @Test func everyPaneIsTheSameHeight() {
        #expect(Island.paneHeight > 0)
    }

    /// The spacing scale is a 4pt grid. A stray value here is how a layout starts drifting.
    @Test func spacingStaysOnTheGrid() {
        let scale = [Island.Space.xs, Island.Space.s, Island.Space.m, Island.Space.l, Island.Space.xl]
        for value in scale {
            #expect(value.truncatingRemainder(dividingBy: 4) == 0, "\(value) is off the grid")
        }
        #expect(scale == scale.sorted())
    }

    /// Radii step up, so a tile nested in a card never looks squarer than the card.
    @Test func radiiIncreaseWithSurfaceSize() {
        #expect(Island.Radius.control < Island.Radius.tile)
        #expect(Island.Radius.tile < Island.Radius.card)
        #expect(Island.Radius.card < Island.Radius.panel)
    }
}
