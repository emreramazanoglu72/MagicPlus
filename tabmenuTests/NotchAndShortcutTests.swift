//
//  NotchAndShortcutTests.swift
//  tabmenuTests
//

import Testing
import AppKit
import Carbon.HIToolbox
import Foundation
@testable import tabmenu

@Suite("Notch activities")
struct NotchActivityTests {
    private let track = NowPlaying(
        source: .system,
        title: "Song",
        artist: "Artist",
        album: "Album",
        isPlaying: true,
        artworkURL: nil,
        position: nil,
        duration: nil
    )

    /// A meeting about to start must never be buried under a track change.
    @Test func meetingsOutrankEverythingElse() {
        let meeting = NotchActivity.meeting(
            AgendaEvent(
                id: "1",
                title: "Standup",
                startDate: Date(),
                endDate: Date().addingTimeInterval(600),
                location: nil,
                meetingURL: nil,
                calendarColor: .blue
            )
        )
        #expect(meeting.priority > NotchActivity.nowPlaying(track).priority)
        #expect(meeting.priority > NotchActivity.volume(0.5).priority)
        #expect(meeting.priority > NotchActivity.filesAdded(2).priority)
    }

    @Test func volumeOutranksPlayback() {
        #expect(NotchActivity.volume(0.5).priority > NotchActivity.nowPlaying(track).priority)
    }

    /// Repeated volume presses must replace one another rather than queue up.
    @Test func sameKindSharesAnIdentifier() {
        #expect(NotchActivity.volume(0.1).kindIdentifier == NotchActivity.volume(0.9).kindIdentifier)
        #expect(NotchActivity.volume(0.1).kindIdentifier != NotchActivity.nowPlaying(track).kindIdentifier)
    }

    @Test func volumeIsTheBriefestActivity() {
        let volume = NotchActivity.volume(0.5).duration
        #expect(volume < NotchActivity.nowPlaying(track).duration)
        #expect(volume < NotchActivity.filesAdded(1).duration)
    }

    @Test func everyActivityDisappearsOnItsOwn() {
        let all: [NotchActivity] = [
            .nowPlaying(track), .volume(0.5), .filesAdded(3),
            .power(isCharging: true, percentage: 80)
        ]
        for activity in all {
            #expect(activity.duration > .zero)
            #expect(activity.duration <= .seconds(5))
            #expect(activity.sideWidth > 0)
        }
    }
}

@Suite("Keyboard shortcuts")
struct HotKeyComboTests {
    @Test func modifiersMapOntoCarbonFlags() {
        let combo = HotKeyCombo(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command, .shift])
        #expect(combo.carbonModifiers == UInt32(cmdKey) | UInt32(shiftKey))
    }

    @Test func allFourModifiersSurvive() {
        let combo = HotKeyCombo(keyCode: 0, modifiers: [.command, .option, .control, .shift])
        #expect(combo.carbonModifiers == UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey) | UInt32(shiftKey))
    }

    /// A shortcut with no modifier would swallow ordinary typing system-wide.
    @Test func plainKeysAreRejected() {
        #expect(!HotKeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: []).isValid)
        #expect(!HotKeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift]).isValid)
    }

    @Test func modifiedKeysAreAccepted() {
        #expect(HotKeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command]).isValid)
        #expect(HotKeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [.option]).isValid)
    }

    @Test func displayStringOrdersModifiersLikeMacOS() {
        let combo = HotKeyCombo(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command, .shift, .control])
        let symbols = combo.displayString.prefix(3)
        #expect(symbols == "⌃⇧⌘")
    }

    @Test func roundTripsThroughJSON() throws {
        let combo = HotKeyCombo(keyCode: 42, modifiers: [.control, .option])
        let decoded = try JSONDecoder().decode(HotKeyCombo.self, from: JSONEncoder().encode(combo))
        #expect(decoded == combo)
    }

    /// Every bindable action needs a stable identifier, since defaults are keyed by it.
    @Test func actionIdentifiersAreUnique() {
        let identifiers = HotKeyAction.allCases.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test func defaultShortcutsAreAllValid() {
        for action in HotKeyAction.allCases {
            guard let combo = action.defaultCombo else { continue }
            #expect(combo.isValid, "\(action.id) has an unusable default")
        }
    }

    @Test func defaultShortcutsDoNotCollide() {
        let combos = HotKeyAction.allCases.compactMap(\.defaultCombo)
        let unique = Set(combos)
        #expect(unique.count == combos.count, "two commands share a default shortcut")
    }
}

@Suite("Workspace layouts")
struct WorkspaceLayoutTests {
    private let placement = WindowPlacement(
        bundleIdentifier: "com.apple.dt.Xcode",
        applicationName: "Xcode",
        title: "tabmenu.xcodeproj",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600)
    )

    @Test func prefersAnExactTitleMatch() {
        let windows: [(bundleIdentifier: String?, title: String)] = [
            ("com.apple.dt.Xcode", "other.xcodeproj"),
            ("com.apple.dt.Xcode", "tabmenu.xcodeproj")
        ]
        #expect(WorkspaceLayoutStore.matchIndex(for: placement, in: windows) == 1)
    }

    /// A renamed document should still land in the right place.
    @Test func fallsBackToAnyWindowOfTheSameApp() {
        let windows: [(bundleIdentifier: String?, title: String)] = [
            ("com.apple.Safari", "News"),
            ("com.apple.dt.Xcode", "renamed.xcodeproj")
        ]
        #expect(WorkspaceLayoutStore.matchIndex(for: placement, in: windows) == 1)
    }

    @Test func returnsNilWhenTheAppIsNotRunning() {
        let windows: [(bundleIdentifier: String?, title: String)] = [("com.apple.Safari", "News")]
        #expect(WorkspaceLayoutStore.matchIndex(for: placement, in: windows) == nil)
    }

    @Test func layoutListsEachApplicationOnce() {
        let layout = WorkspaceLayout(name: "Coding", placements: [
            placement,
            WindowPlacement(bundleIdentifier: "com.apple.dt.Xcode", applicationName: "Xcode", title: "b", frame: .zero),
            WindowPlacement(bundleIdentifier: "com.apple.Terminal", applicationName: "Terminal", title: "c", frame: .zero)
        ])
        #expect(layout.applicationNames == ["Xcode", "Terminal"])
    }
}
