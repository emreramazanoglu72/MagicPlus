//
//  DockTweakTests.swift
//  tabmenuTests
//

import AppKit
import Foundation
import Testing
@testable import tabmenu

/// Written against a domain of its own. These settings live in the Dock's preferences and take
/// effect by restarting it, so a test that used the real domain would rearrange the Dock of whoever
/// ran the suite — and the one property worth proving here is precisely that this code does not
/// disturb anything it was not asked to.
@MainActor
@Suite("Dock settings")
struct DockTweakTests {
    private static let domain = "com.tabmenu.docktests"

    private func makeService() -> DockTweakService {
        UserDefaults.standard.removePersistentDomain(forName: Self.domain)
        CFPreferencesAppSynchronize(Self.domain as CFString)
        // No restart: nothing here may touch a running Dock.
        return DockTweakService(domain: Self.domain, restart: {})
    }

    private func rawValue(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, Self.domain as CFString)
    }

    @Test func everythingStartsAsMacOSShipsIt() {
        let service = makeService()
        for tweak in DockTweakService.Tweak.allCases {
            #expect(!service.isOn(tweak), "\(tweak.rawValue) was on before anyone asked")
        }
        #expect(service.minimizeEffect == .genie)
        #expect(!service.hasChanges)
    }

    /// Off has to mean "the key is gone", not "the key says false". A Dock preference written
    /// `false` is a decision; an absent one is macOS's own default, and only the second is
    /// something this app can honestly claim to have restored.
    @Test func switchingOffRemovesTheKeyRatherThanWritingFalse() {
        let service = makeService()

        service.set(.singleAppMode, on: true)
        #expect(service.isOn(.singleAppMode))
        #expect(rawValue("single-app") as? Bool == true)

        service.set(.singleAppMode, on: false)
        #expect(!service.isOn(.singleAppMode))
        #expect(rawValue("single-app") == nil, "the key is still there, so macOS is not back to its default")
    }

    /// The two settings whose value matters rather than merely existing.
    @Test func writesTheValuesTheDockActuallyReads() {
        let service = makeService()

        service.set(.instantReveal, on: true)
        #expect((rawValue("autohide-delay") as? Double) == 0)

        service.set(.fasterAnimation, on: true)
        let modifier = try! #require(rawValue("autohide-time-modifier") as? Double)
        #expect(modifier > 0 && modifier < 1, "faster, but not so fast it looks broken")

        // This one is on when the key is *false*: the Dock's setting is the animation, not its
        // absence, so a switch called "no launch bounce" has to write the opposite.
        service.set(.noLaunchBounce, on: true)
        #expect(rawValue("launchanim") as? Bool == false)
    }

    @Test func theHiddenMinimiseEffectIsWrittenAndTheDefaultIsCleared() {
        let service = makeService()

        service.setMinimizeEffect(.suck)
        #expect(rawValue("mineffect") as? String == "suck")
        #expect(service.minimizeEffect == .suck)

        service.setMinimizeEffect(.scale)
        #expect(rawValue("mineffect") as? String == "scale")

        // Genie is the Dock's own, so choosing it removes the key rather than pinning a value.
        service.setMinimizeEffect(.genie)
        #expect(rawValue("mineffect") == nil)
        #expect(service.minimizeEffect == .genie)
    }

    /// Restoring must take back what this wrote and nothing else. A blanket wipe of the Dock's
    /// domain would take the user's icons with it.
    @Test func restoringLeavesEverythingItDidNotWriteAlone() {
        let service = makeService()
        CFPreferencesSetAppValue("tilesize" as CFString, NSNumber(value: 48), Self.domain as CFString)
        CFPreferencesSetAppValue("orientation" as CFString, "left" as NSString, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)

        service.set(.runningAppsOnly, on: true)
        service.set(.dimHiddenApps, on: true)
        service.setMinimizeEffect(.suck)
        #expect(service.hasChanges)

        service.restoreDefaults()

        #expect(!service.hasChanges)
        for tweak in DockTweakService.Tweak.allCases {
            #expect(rawValue(tweak.key) == nil)
        }
        #expect(rawValue("mineffect") == nil)
        // Settings this page never offered are none of its business.
        #expect(rawValue("tilesize") as? Int == 48)
        #expect(rawValue("orientation") as? String == "left")
    }

    // MARK: - Separators

    /// The list of icons belongs to the user. Adding a blank tile must leave every real one where
    /// it was, in the order they arranged it.
    @Test func addingASeparatorKeepsEveryIconAndItsOrder() {
        let service = makeService()
        let apps: [[String: Any]] = [
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "com.apple.Safari"]],
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "com.apple.mail"]],
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "com.apple.Terminal"]]
        ]
        CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)

        service.addSeparator()
        service.addSeparator()

        #expect(service.separatorCount == 2)
        let stored = try! #require(rawValue("persistent-apps") as? [[String: Any]])
        #expect(stored.count == 5)

        let identifiers = stored.compactMap { app in
            (app["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        }
        #expect(identifiers == ["com.apple.Safari", "com.apple.mail", "com.apple.Terminal"])
    }

    @Test func removingSeparatorsTakesOutOnlyTheBlankOnes() {
        let service = makeService()
        let apps: [[String: Any]] = [
            ["tile-type": "spacer-tile"],
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "com.apple.Safari"]],
            ["tile-type": "small-spacer-tile"],
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "com.apple.mail"]]
        ]
        CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)

        #expect(service.separatorCount == 2)
        service.removeSeparators()

        #expect(service.separatorCount == 0)
        let stored = try! #require(rawValue("persistent-apps") as? [[String: Any]])
        #expect(stored.count == 2)
        let identifiers = stored.compactMap { app in
            (app["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        }
        #expect(identifiers == ["com.apple.Safari", "com.apple.mail"])
    }

    // MARK: - Module lifecycle

    /// A module that is off must not still be changing the Mac. These are system settings, so
    /// switching the module off gives them back rather than merely hiding the pane.
    @Test func switchingTheModuleOffGivesTheDockBack() {
        let service = makeService()
        service.set(.runningAppsOnly, on: true)
        service.set(.noAttentionBounce, on: true)
        #expect(service.hasChanges)

        service.moduleDidChange(isEnabled: false)
        #expect(!service.hasChanges)
        #expect(rawValue("static-only") == nil)
    }

    @Test func switchingTheModuleOnChangesNothingOnItsOwn() {
        let service = makeService()
        service.set(.dimHiddenApps, on: true)

        service.moduleDidChange(isEnabled: true)
        #expect(service.isOn(.dimHiddenApps), "turning the module on must not rewrite the user's choices")
    }
}

/// The one thing a test domain cannot show: that the real Dock reads what this writes.
///
/// Runs against `com.apple.dock` and restarts the actual Dock, so it is asked for rather than
/// assumed, and it puts the list back exactly as it found it:
///
///     TEST_RUNNER_DOCK_LIVE=1 xcodebuild test -only-testing:tabmenuTests/DockLiveTests …
@MainActor
@Suite("Dock live", .enabled(if: ProcessInfo.processInfo.environment["DOCK_LIVE"] == "1"))
struct DockLiveTests {
    private func identifiers() -> [String] {
        let apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
            as? [[String: Any]] ?? []
        return apps.map { app in
            (app["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
                ?? (app["tile-type"] as? String ?? "?")
        }
    }

    @Test func theRealDockTakesASeparatorAndGivesItBack() async throws {
        let service = DockTweakService()
        let before = identifiers()

        // Only safe to run on a Dock with no separators of its own, since removing takes out all
        // of them and this test has no business deleting someone's arrangement.
        try #require(service.separatorCount == 0, "this Dock already has separators; not touching it")

        service.addSeparator()
        #expect(service.separatorCount == 1)
        let during = identifiers()
        #expect(during.count == before.count + 1)
        #expect(during.filter { $0 != "spacer-tile" } == before, "a real icon moved or vanished")

        // Give the Dock time to be terminated and come back, which is what proves launchd brings
        // it straight back rather than leaving the Mac without one.
        try await Task.sleep(for: .seconds(3))
        let dockIsBack = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").isEmpty
        #expect(dockIsBack, "the Dock did not come back")

        service.removeSeparators()
        #expect(service.separatorCount == 0)
        #expect(identifiers() == before, "the Dock was not put back as it was found")

        try await Task.sleep(for: .seconds(3))
        print("DOCK LIVE: \(before.count) tiles, separator added and removed, Dock back")
    }
}

@MainActor
@Suite("Never writing away a Dock")
struct DockArrangementSafetyTests {
    private static let domain = "com.tabmenu.docksafety"

    private func makeService() -> DockTweakService {
        UserDefaults.standard.removePersistentDomain(forName: Self.domain)
        CFPreferencesAppSynchronize(Self.domain as CFString)
        return DockTweakService(domain: Self.domain, restart: {})
    }

    private func apps() -> [[String: Any]]? {
        CFPreferencesCopyAppValue("persistent-apps" as CFString, Self.domain as CFString) as? [[String: Any]]
    }

    /// A domain that cannot be read looks exactly like a Dock with nothing in it, and the two have
    /// to be told apart: writing the second back over the first replaces somebody's arrangement
    /// with nothing. It did, once, which is why this test exists.
    @Test func anUnreadableArrangementIsNeverWrittenBack() {
        let service = makeService()
        #expect(apps() == nil, "the domain starts with no arrangement at all")

        service.addSeparator()
        #expect(apps() == nil, "a separator was added to a Dock that could not be read")

        service.removeSeparators()
        #expect(apps() == nil, "an empty list was written over an unreadable one")
    }

    /// And with a real arrangement present it behaves normally — the guard must not turn into a
    /// refusal to work.
    @Test func aReadableArrangementStillTakesASeparator() {
        let service = makeService()
        let arrangement: [[String: Any]] = [
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "com.apple.Safari"]]
        ]
        CFPreferencesSetAppValue("persistent-apps" as CFString, arrangement as CFArray, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)

        service.addSeparator()
        #expect(apps()?.count == 2)
        service.removeSeparators()
        #expect(apps()?.count == 1, "the application survived")
    }
}
