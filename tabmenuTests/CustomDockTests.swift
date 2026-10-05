//
//  CustomDockTests.swift
//  tabmenuTests
//

import AppKit
import Foundation
import Testing
@testable import tabmenu

@Suite("Dock style")
struct DockStyleTests {
    /// Stored as one JSON value, so it has to survive the trip and it has to tolerate JSON written
    /// by an older build that did not have every field yet.
    @Test func survivesBeingStoredAndRead() throws {
        var style = DockStyle()
        style.surface = .solid
        style.tintHex = "1C1C1E"
        style.iconSize = 52
        style.edge = .top

        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(DockStyle.self, from: data)
        #expect(decoded == style)
    }

    @Test func aFieldAddedLaterReadsAsItsDefault() throws {
        // What a build from before `edgeMargin` existed would have written.
        let old = #"{"edge":"bottom","surface":"glass","tintHex":"","backgroundOpacity":0.5,"cornerRadius":22,"iconSize":48,"magnifies":true,"magnifiedSize":76,"spacing":6,"showsRunningApps":true,"showsRunningIndicators":true}"#
        let style = try JSONDecoder().decode(DockStyle.self, from: Data(old.utf8))
        #expect(style.edgeMargin == DockStyle().edgeMargin)
        #expect(style.iconSize == 48)
    }

    /// The app draws one thing, so the defaults have to be that thing. There is no separate
    /// "default theme" that could disagree with them any more.
    @Test func theDefaultsAreTheBar() {
        let style = DockStyle()
        #expect(style.fillsEdge, "a bar spans its edge")
        #expect(style.edgeMargin == 0, "flush against the edge")
        #expect(style.reservesSpace)

        // The icon has to fit inside the bar with room left for the mark under it, and the bar has
        // to stay short enough to still be a bar. Stated as the relationship rather than as the
        // numbers of the day, which is what this used to be and what broke when they changed.
        #expect(style.barIconSize <= style.iconSize, "the strip never draws bigger than it was asked to")
        #expect(style.barHeight > style.barIconSize + 8, "no room for the running mark")
        #expect(style.barHeight <= 64, "past this it stops being a bar")
    }

    /// A full-screen window is the system's to place, and the enforcer used to shrink one by the
    /// height of the strip every tick for as long as you stayed on that Space.
    @Test func onlyAWindowCoveringItsWholeDisplayCanBeFullScreen() {
        let display = CGSize(width: 1800, height: 1169)

        #expect(DockReplacementController.coversWholeDisplay(display, display: display))
        // A point of rounding either way still counts.
        #expect(DockReplacementController.coversWholeDisplay(
            CGSize(width: 1799.5, height: 1168.4), display: display
        ))

        // A zoomed window stops at the menu bar, which is what tells the two apart.
        #expect(!DockReplacementController.coversWholeDisplay(
            CGSize(width: 1800, height: 1130), display: display
        ))
        #expect(!DockReplacementController.coversWholeDisplay(
            CGSize(width: 900, height: 1169), display: display
        ))
    }

    /// The gaps close before the icons shrink.
    ///
    /// Both buy about the same room per point, but one of them is the thing being looked at. A
    /// crowded dock that took it out of the icons first came out at twenty-three points while the
    /// gaps still had eight points of slack in them.
    @Test func aCrowdedDockClosesItsGapsBeforeItShrinksItsIcons() {
        var style = DockStyle()
        style.iconSize = 32
        style.spacing = 14

        let layout = DockLayout(tileCount: 26)
        let full = layout.windowSize(for: style).width
        // Tight enough to need something given up, loose enough that the gaps can cover it.
        let clamped = layout.clamped(style, toLength: full - 100)

        #expect(clamped.iconSize == style.iconSize, "the icons were the first thing given up")
        #expect(clamped.spacing < style.spacing)
        #expect(clamped.spacing >= DockLayout.minimumSpacing, "icons touching each other are one icon")
        #expect(layout.windowSize(for: clamped).width <= full - 100)
    }

    /// And when closing them is not enough, the icons do shrink — a dock wider than the screen is
    /// half off the edge, which is worse than a small one.
    @Test func iconsShrinkOnceTheGapsAreGone() {
        var style = DockStyle()
        style.iconSize = 32
        style.spacing = 14

        let layout = DockLayout(tileCount: 26)
        let clamped = layout.clamped(style, toLength: 600)

        #expect(clamped.spacing == DockLayout.minimumSpacing)
        #expect(clamped.iconSize < style.iconSize)
        #expect(layout.windowSize(for: clamped).width <= 600)
    }

    /// Whatever is asked for, the strip stays a strip. The icon-size slider goes to 96, which is a
    /// dock's size, not a bar's — a bar that honoured it would be a sixth of the screen.
    @Test func anOversizedIconStillLeavesABar() {
        var style = DockStyle()
        style.iconSize = 96

        #expect(style.barIconSize < style.iconSize)
        #expect(style.barHeight <= 64)
    }
}

@Suite("Dock contents")
struct DockTileSourceTests {
    private static let domain = "com.tabmenu.docktiletests"

    private func write(apps: [[String: Any]], others: [[String: Any]] = []) {
        UserDefaults.standard.removePersistentDomain(forName: Self.domain)
        CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, Self.domain as CFString)
        CFPreferencesSetAppValue("persistent-others" as CFString, others as CFArray, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)
    }

    private func appEntry(_ path: String, label: String, bundleID: String) -> [String: Any] {
        [
            "tile-type": "file-tile",
            "tile-data": [
                "file-label": label,
                "bundle-identifier": bundleID,
                "file-data": ["_CFURLString": "file://\(path)"]
            ]
        ]
    }

    /// The order the user arranged, kept. A dock that reorders their icons is a dock they switch
    /// off within the minute.
    @Test func readsThePinnedIconsInOrder() {
        write(apps: [
            appEntry("/System/Applications/Safari.app/", label: "Safari", bundleID: "com.apple.Safari"),
            appEntry("/Applications/Opera.app/", label: "Opera", bundleID: "com.operasoftware.Opera"),
            appEntry("/System/Applications/Mail.app/", label: "Mail", bundleID: "com.apple.mail")
        ])

        let tiles = DockTileSource.pinnedTiles(domain: Self.domain)
        #expect(tiles.map(\.name) == ["Safari", "Opera", "Mail"])
        #expect(tiles.map(\.bundleIdentifier) == ["com.apple.Safari", "com.operasoftware.Opera", "com.apple.mail"])
        let allApplications = tiles.allSatisfy(\.isApplication)
        #expect(allApplications)
    }

    /// The Dock's label is localised — "Uygulamalar" rather than "Applications" — so repeating it
    /// is the only way the dock reads the same as the one it replaces.
    @Test func keepsTheLabelTheDockItselfShows() {
        write(apps: [
            appEntry("/System/Applications/Apps.app/", label: "Uygulamalar", bundleID: "com.apple.apps.launcher")
        ])
        #expect(DockTileSource.pinnedTiles(domain: Self.domain).first?.name == "Uygulamalar")
    }

    @Test func foldersComeAfterTheAppsAsTheyDoInTheDock() {
        write(
            apps: [appEntry("/Applications/Opera.app/", label: "Opera", bundleID: "com.operasoftware.Opera")],
            others: [[
                "tile-type": "directory-tile",
                "tile-data": [
                    "file-label": "İndirilenler",
                    "file-data": ["_CFURLString": "file:///Users/someone/Downloads/"]
                ]
            ]]
        )

        let tiles = DockTileSource.pinnedTiles(domain: Self.domain)
        #expect(tiles.count == 2)
        #expect(tiles[0].isApplication)
        #expect(tiles[1].kind == .folder)
        #expect(tiles[1].name == "İndirilenler")
    }

    @Test func spacerTilesBecomeSeparators() {
        write(apps: [
            appEntry("/Applications/Opera.app/", label: "Opera", bundleID: "com.operasoftware.Opera"),
            ["tile-type": "spacer-tile"],
            appEntry("/System/Applications/Mail.app/", label: "Mail", bundleID: "com.apple.mail")
        ])

        let tiles = DockTileSource.pinnedTiles(domain: Self.domain)
        #expect(tiles.count == 3)
        #expect(tiles[1].kind == .separator)
        #expect(tiles[1].url == nil)
    }

    @Test func anEmptyDomainIsNotACrash() {
        UserDefaults.standard.removePersistentDomain(forName: Self.domain)
        CFPreferencesAppSynchronize(Self.domain as CFString)
        #expect(DockTileSource.pinnedTiles(domain: Self.domain).isEmpty)
    }

    /// The app drawing the dock has no business appearing in it, and neither does anything already
    /// pinned.
    @MainActor
    @Test func runningAppsExcludeWhatIsPinnedAndOurself() {
        let pinned = [
            DockTile(
                id: "pinned",
                kind: .application(bundleIdentifier: "com.apple.finder"),
                url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                name: "Finder"
            )
        ]
        let running = DockTileSource.runningTiles(excluding: pinned)

        let includesPinned = running.contains { $0.bundleIdentifier == "com.apple.finder" }
        let includesSelf = running.contains { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let allTransient = running.allSatisfy(\.isTransient)
        let allRunning = running.allSatisfy(\.isRunning)
        #expect(!includesPinned)
        #expect(!includesSelf)
        #expect(allTransient)
        #expect(allRunning)
    }
}

@MainActor
@Suite("Dropping files on the dock")
struct DockDropTests {
    private func makeController() -> DockReplacementController {
        DockReplacementController(preferences: Preferences(defaults: UserDefaults(suiteName: "dock.drop") ?? .standard))
    }

    private func tile(_ kind: DockTile.Kind, url: URL?) -> DockTile {
        DockTile(id: "t", kind: kind, url: url, name: "t")
    }

    /// The bin means the bin. Files are moved there and can be put back — the difference between
    /// the Dock's bin and `rm`, and the reason this is allowed to happen without a confirmation.
    @Test func droppingOnTheBinMovesFilesThereRatherThanDeletingThem() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dock-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        #expect(makeController().accept([file], on: tile(.trash, url: nil)))
        #expect(!FileManager.default.fileExists(atPath: file.path), "it should have left where it was")
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func droppingOnAFolderMovesFilesIntoIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dock-drop-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        #expect(makeController().accept([file], on: tile(.folder, url: folder)))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("note.txt").path))
        try? FileManager.default.removeItem(at: root)
    }

    /// A drop that reports success and does nothing is a file somebody believes they have filed.
    @Test func aTileWithNothingToDoWithFilesRefusesTheDrop() {
        let controller = makeController()
        let file = URL(fileURLWithPath: "/tmp/whatever.txt")

        #expect(!controller.accept([], on: tile(.trash, url: nil)), "nothing dropped is nothing done")
        #expect(!controller.accept([file], on: tile(.separator, url: nil)))
        #expect(!controller.accept([file], on: tile(.application(bundleIdentifier: "x"), url: nil)),
                "an application with no bundle on disk cannot open anything")
    }

    /// One file that will not move must not take the rest of the drop with it.
    @Test func aFolderThatAlreadyHasThatNameKeepsWhatItHas() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dock-drop-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "existing".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let incoming = root.appendingPathComponent("note.txt")
        try "incoming".write(to: incoming, atomically: true, encoding: .utf8)

        #expect(!makeController().accept([incoming], on: tile(.folder, url: folder)))
        let kept = try String(contentsOf: folder.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(kept == "existing", "the file that was there must not be overwritten")
        #expect(FileManager.default.fileExists(atPath: incoming.path), "and the dropped one stays put")
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Parking the strip")
struct AutoHideTests {
    /// A strip that hides itself leaves a sliver: enough to be reachable by shoving the pointer at
    /// the edge, little enough not to be a stripe across the display.
    @Test func theSliverIsSmallButReachable() {
        #expect(DockStyle.revealStrip > 0)
        #expect(DockStyle.revealStrip < 8)
    }

    /// Off by default. A dock that is not there is a dock somebody has to remember exists.
    @Test func itIsSomethingYouTurnOn() {
        #expect(DockStyle().autoHides == false)
    }

    /// The setting survives being stored, like every other one.
    @Test func theSettingIsRemembered() throws {
        var style = DockStyle()
        style.autoHides = true
        let read = try JSONDecoder().decode(DockStyle.self, from: JSONEncoder().encode(style))
        #expect(read.autoHides)
    }

    /// A style saved before this existed reads as off rather than as a bar that has vanished.
    @Test func anOlderStyleDoesNotStartHiding() throws {
        let old = #"{"appearanceVersion":\#(DockStyle.appearanceVersion),"edge":"bottom"}"#
        let style = try JSONDecoder().decode(DockStyle.self, from: Data(old.utf8))
        #expect(style.autoHides == false)
    }
}

@Suite("Folder stacks")
struct FolderStackTests {
    /// Newest first, because a folder pinned to a dock is almost always somewhere things arrive.
    @MainActor
    @Test func contentsComeBackNewestFirst() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Written oldest to newest, with distinct dates set by hand so the order cannot be an
        // accident of how fast the file system is.
        for (index, name) in ["old.txt", "middle.txt", "new.txt"].enumerated() {
            let url = root.appendingPathComponent(name)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60)],
                ofItemAtPath: url.path
            )
        }

        let entries = await FolderStackPanel.read(root)
        #expect(entries.map(\.name) == ["new.txt", "middle.txt", "old.txt"])
    }

    @MainActor
    @Test func aFolderThatIsNotThereIsNotACrash() async {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString)")
        #expect(await FolderStackPanel.read(missing).isEmpty)
    }

    /// Directories are marked, so the grid can tell a folder from a file.
    @MainActor
    @Test func directoriesAreRecognised() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stack-\(UUID().uuidString)")
        let inner = root.appendingPathComponent("Inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let entries = await FolderStackPanel.read(root)
        #expect(entries.first { $0.name == "Inner" }?.isDirectory == true)
        #expect(entries.first { $0.name == "file.txt" }?.isDirectory == false)
    }

    /// A folder with thousands of entries is a folder somebody opens in the Finder; the panel has
    /// to open at once rather than completely.
    @Test func theListIsBounded() {
        #expect(FolderStackPanel.entryLimit > 0)
        #expect(FolderStackPanel.entryLimit <= 200)
    }
}

@Suite("Rearranging the dock")
struct DockReorderTests {
    private let pins = ["a", "b", "c", "d"]

    /// The off-by-one this function exists for: the anchor has to be found *after* the thing being
    /// moved is taken out, or an icon dragged rightwards lands one place short of the drop.
    @Test func anIconDraggedRightwardsLandsWhereItWasDropped() {
        #expect(DockReplacementController.reordered(pins, moving: ["a"], toward: "c") == ["b", "a", "c", "d"])
        #expect(DockReplacementController.reordered(pins, moving: ["a"], toward: "d") == ["b", "c", "a", "d"])
    }

    @Test func anIconDraggedLeftwardsLandsThereToo() {
        #expect(DockReplacementController.reordered(pins, moving: ["d"], toward: "b") == ["a", "d", "b", "c"])
    }

    /// Moving and adding are one operation, so a move must not leave a copy behind.
    @Test func movingSomethingAlreadyThereDoesNotDuplicateIt() {
        let result = DockReplacementController.reordered(pins, moving: ["b"], toward: "d")
        #expect(result.count == pins.count)
        #expect(result.filter { $0 == "b" }.count == 1)
    }

    @Test func somethingNewIsAdded() {
        #expect(DockReplacementController.reordered(pins, moving: ["z"], toward: "b") == ["a", "z", "b", "c", "d"])
    }

    /// No anchor means the end: dropped past the last icon, or on something not pinned at all.
    @Test func withoutAnAnchorItGoesToTheEnd() {
        #expect(DockReplacementController.reordered(pins, moving: ["a"], toward: nil) == ["b", "c", "d", "a"])
        #expect(DockReplacementController.reordered(pins, moving: ["a"], toward: "nothing") == ["b", "c", "d", "a"])
    }

    @Test func severalAtOnceKeepTheirOwnOrder() {
        #expect(DockReplacementController.reordered(pins, moving: ["a", "d"], toward: "c") == ["b", "a", "d", "c"])
    }
}

@Suite("Showing the desktop")
struct ShowDesktopTests {
    private func candidate(
        _ pid: pid_t, regular: Bool = true, hidden: Bool = false, ourself: Bool = false
    ) -> ShowDesktop.Candidate {
        ShowDesktop.Candidate(
            processIdentifier: pid, isRegular: regular, isAlreadyHidden: hidden, isOurself: ourself
        )
    }

    @Test func ordinaryApplicationsAreTheOnesThatGo() {
        #expect(ShowDesktop.choose(from: [candidate(1), candidate(2)]) == [1, 2])
    }

    /// Agents and accessories have no windows to clear, and hiding them can stop things people are
    /// relying on — a menu bar app, for one.
    @Test func backgroundApplicationsAreLeftAlone() {
        #expect(ShowDesktop.choose(from: [candidate(1), candidate(2, regular: false)]) == [1])
    }

    /// The screen would be cleared and then the bar that cleared it would be gone with it.
    @Test func itNeverHidesThisApp() {
        #expect(ShowDesktop.choose(from: [candidate(1, ourself: true), candidate(2)]) == [2])
    }

    /// "Everything hidden" is not "everything this hid". An application somebody hid themselves
    /// before pressing the sliver has to still be hidden after pressing it again.
    @Test func somethingAlreadyHiddenIsNotClaimed() {
        #expect(ShowDesktop.choose(from: [candidate(1, hidden: true), candidate(2)]) == [2])
    }

    @Test func nothingToHideIsNotAnError() {
        #expect(ShowDesktop.choose(from: []).isEmpty)
        #expect(ShowDesktop.choose(from: [candidate(1, regular: false)]).isEmpty)
    }
}

@Suite("Dock fits the screen")
struct DockFitTests {
    /// The numbers from a real Mac: thirty tiles at 64pt along an 1800pt edge. Two thousand points
    /// of dock on eighteen hundred points of screen is not a dock.
    @Test func shrinksIconsUntilTheDockFits() {
        var style = DockStyle()
        style.iconSize = 64
        let layout = DockLayout(tileCount: 30)
        let available: CGFloat = 1784

        let unclamped = layout.windowSize(for: style).width
        #expect(unclamped > available, "the case being fixed has to start out broken")

        let clamped = layout.clamped(style, toLength: available)
        #expect(clamped.iconSize < style.iconSize)
        #expect(layout.windowSize(for: clamped).width <= available,
                "still \(layout.windowSize(for: clamped).width)pt on a \(available)pt screen")
    }

    @Test func leavesAComfortableDockAlone() {
        let style = DockStyle()
        let layout = DockLayout(tileCount: 8)
        #expect(layout.clamped(style, toLength: 1600) == style)
    }

    @Test func neverShrinksBelowSomethingClickable() {
        let style = DockStyle()
        let clamped = DockLayout(tileCount: 200).clamped(style, toLength: 900)
        #expect(clamped.iconSize >= 16)
    }
}

@Suite("Dock alignment")
struct DockAlignmentTests {
    private let layout = DockLayout(tileCount: 10)
}

@Suite("Dock screen reservation")
struct DockReservationTests {
    /// An instance of its own, never `shared`.
    ///
    /// The test host *is* the app, so the running dock writes reservations into the shared one while
    /// the suite is measuring it — two of these tests failed on exactly that, comparing numbers the
    /// app had just overwritten. A test that reaches into live application state is not measuring
    /// its own subject.
    private func makeReservation() -> DockReservation {
        DockReservation()
    }

    @Test func aTaskbarAtTheBottomTakesSpaceOffTheBottom() {
        let reservation = makeReservation()
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)
        reservation.set(.init(bottom: 49), forScreenNumber: 1)

        let usable = reservation.applying(to: screen, screenNumber: 1)
        #expect(usable.minY == 49)
        #expect(usable.height == 1081)
        #expect(usable.width == 1800)
    }

    /// A reservation belongs to the screen the dock is on. Subtracting it from another display's
    /// area would push windows around on a screen with no dock on it at all.
    @Test func aReservationOnlyAffectsItsOwnScreen() {
        let reservation = makeReservation()
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)
        reservation.set(.init(left: 232), forScreenNumber: 1)

        #expect(reservation.applying(to: screen, screenNumber: 2) == screen)
    }

    @Test func noDockMeansNoReservation() {
        let reservation = makeReservation()
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)
        #expect(reservation.applying(to: screen, screenNumber: 1) == screen)

        reservation.set(.init(left: 232), forScreenNumber: 1)
        reservation.clearAll()
        #expect(reservation.applying(to: screen, screenNumber: 1) == screen,
                "a dock that is gone reserves nothing")
    }

    /// A width someone dragged to something absurd must not hand back an inverted rectangle for
    /// every window in the app to be placed into.
    @Test func anAbsurdReservationStillLeavesSomethingUsable() {
        let reservation = makeReservation()
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)
        reservation.set(.init(left: 4000), forScreenNumber: 1)

        let usable = reservation.applying(to: screen, screenNumber: 1)
        #expect(usable.width >= 120)
        #expect(usable.height >= 120)
    }
}

@Suite("Stored styles")
struct StoredStyleTests {
    /// A field this build added has to read as its own default out of JSON written before it
    /// existed, and the fields that were written have to survive. Compared against `DockStyle()`
    /// rather than against numbers copied into the test: the defaults are allowed to change, and a
    /// test that hardcodes them fails for the wrong reason when they do.
    @Test func missingFieldsReadAsDefaultsAndPresentOnesSurvive() throws {
        let old = #"{"appearanceVersion":\#(DockStyle.appearanceVersion),"edge":"top","iconSize":48,"fillsEdge":false}"#
        let style = try JSONDecoder().decode(DockStyle.self, from: Data(old.utf8))

        #expect(style.reservesSpace == DockStyle().reservesSpace)

        #expect(style.iconSize == 48, "a field that was written must not be overwritten")
        #expect(style.fillsEdge == false)
        #expect(style.edge == .top)
    }

    /// The look is allowed to be replaced; the decisions are not.
    ///
    /// Everyone who has run the app has a style with every old value written into it, so new
    /// defaults alone would reach new installs only and leave every existing user on the old bar
    /// for ever. A version bump takes the fields that describe how the strip is *drawn* fresh.
    @Test func aRedesignReachesStylesSavedBeforeIt() throws {
        let old = #"{"surface":"glass","tintHex":"FF0000","backgroundOpacity":0.99,"alignment":"trailing","edge":"top","iconSize":40,"fillsEdge":false,"reservesSpace":false}"#
        let style = try JSONDecoder().decode(DockStyle.self, from: Data(old.utf8))
        let fresh = DockStyle()

        #expect(style.surface == fresh.surface, "how it is painted is ours")
        #expect(style.tintHex == fresh.tintHex)
        #expect(style.backgroundOpacity == fresh.backgroundOpacity)
        #expect(style.alignment == fresh.alignment)
        #expect(style.appearanceVersion == DockStyle.appearanceVersion)

        #expect(style.edge == .top, "where it sits is a decision somebody made")
        #expect(style.iconSize == 40)
        #expect(style.fillsEdge == false)
        #expect(style.reservesSpace == false)
    }

    /// And it happens once. A style already on this look keeps whatever was chosen for it, or
    /// every colour anyone picks would be thrown away on the next read.
    @Test func aStyleAlreadyOnThisLookIsLeftAlone() throws {
        let current = #"{"appearanceVersion":\#(DockStyle.appearanceVersion),"surface":"glass","tintHex":"FF0000","alignment":"trailing"}"#
        let style = try JSONDecoder().decode(DockStyle.self, from: Data(current.utf8))

        #expect(style.surface == .glass)
        #expect(style.tintHex == "FF0000")
        #expect(style.alignment == .trailing)
    }

    /// A strip that paints itself dark has to draw light contents whatever the desktop is doing,
    /// and one thin enough to show the wallpaper through has to follow the desktop.
    @Test func aBarThatPaintsItsOwnSurfaceDecidesItsOwnAppearance() {
        #expect(DockStyle().contentScheme == .dark, "the default strip is a dark surface")

        var pale = DockStyle()
        pale.tintHex = "F2F2F5"
        #expect(pale.contentScheme == .light)

        var glass = DockStyle()
        glass.surface = .glass
        #expect(glass.contentScheme == nil, "glass is whatever is behind it")

        var sheer = DockStyle()
        sheer.backgroundOpacity = 0.2
        #expect(sheer.contentScheme == nil, "a fill this thin is not a surface")
    }
}

@MainActor
@Suite("Start menu")
struct StartMenuTests {
    private func makeModel(_ names: [String]) -> StartMenuPanel.Model {
        let model = StartMenuPanel.Model()
        model.apps = names.map { name in
            LaunchableApp(id: name, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
        }
        return model
    }

    @Test func anEmptySearchShowsEverything() {
        let model = makeModel(["Safari", "Mail", "Terminal"])
        #expect(model.results.count == 3)
        model.query = "   "
        #expect(model.results.count == 3, "whitespace is not a search")
    }

    @Test func searchIgnoresCase() {
        let model = makeModel(["Safari", "Mail", "Terminal"])
        model.query = "sAf"
        #expect(model.results.map(\.name) == ["Safari"])
    }

    @Test func nothingMatchingIsAnEmptyResultRatherThanEverything() {
        let model = makeModel(["Safari", "Mail"])
        model.query = "zzz"
        #expect(model.results.isEmpty)
    }

    /// Every command has to be labelled and have a glyph, or the row of buttons at the bottom is a
    /// row of mysteries.
    @Test func everySessionCommandIsPresentable() {
        for command in SessionCommand.allCases {
            #expect(!command.title.isEmpty)
            #expect(!command.symbolName.isEmpty)
        }
        #expect(SessionCommand.allCases.count == 5)
    }
}

@MainActor
@Suite("Parking the system Dock")
struct DockParkingTests {
    /// Hiding the Dock is not enough: a hidden Dock still slides out when the pointer reaches the
    /// edge it lives on, and with our own bar along the bottom, every trip to that bar brought it
    /// out. So it is moved to an edge the pointer has no reason to visit.
    @Test func theSystemDockIsParkedAwayFromOurs() {
        var style = DockStyle()
        for edge in DockStyle.Edge.allCases {
            style.edge = edge
            let parked = DockReplacementController.parkingEdge(for: style)
            #expect(parked == "right")
            #expect(parked != edge.rawValue,
                    "parking it on the edge ours occupies is the bug this exists to avoid")
        }
    }

    /// The bar is a horizontal strip, and a strip cannot stand on its end. Offering a position it
    /// cannot occupy is what the vertical edges were.
    @Test func onlyTheEdgesAStripCanOccupyAreOffered() {
        #expect(DockStyle.Edge.allCases.count == 2)
        #expect(DockStyle.Edge.allCases.allSatisfy { !$0.isVertical })
    }

    /// A style stored while the vertical edges existed has to land somewhere sensible rather than
    /// refusing to decode.
    @Test func aStoredVerticalEdgeFallsBackToTheBottom() throws {
        let old = #"{"edge":"left","iconSize":24}"#
        let style = try JSONDecoder().decode(DockStyle.self, from: Data(old.utf8))
        #expect(style.edge == .bottom)
        #expect(style.iconSize == 24, "the rest of the style still survives")
    }
}

@MainActor
@Suite("Keeping windows out of the strip")
struct DockEnforcementTests {
    private let usable = CGRect(x: 0, y: 0, width: 1800, height: 1084)

    /// The complaint this exists for: a window sitting under the bar, its bottom out of sight.
    @Test func aWindowOverlappingTheStripIsLiftedOutOfIt() {
        let intruding = CGRect(x: 100, y: 700, width: 900, height: 500)
        let corrected = DockReplacementController.clamp(intruding, into: usable)

        #expect(corrected.maxY <= usable.maxY, "still hanging into the strip")
        #expect(corrected.width == intruding.width, "moving it is enough; nothing had to shrink")
        #expect(corrected.minX == intruding.minX, "a vertical correction must not move it sideways")
    }

    /// A window too big to fit has to be shrunk, not shoved off the screen.
    @Test func aWindowTallerThanTheAreaIsShrunkToFit() {
        let huge = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let corrected = DockReplacementController.clamp(huge, into: usable)

        #expect(corrected.width == usable.width)
        #expect(corrected.height == usable.height)
        #expect(corrected.minX == usable.minX)
        #expect(corrected.minY == usable.minY)
    }

    @Test func aWindowAlreadyInsideIsLeftExactlyWhereItIs() {
        let fine = CGRect(x: 120, y: 80, width: 800, height: 600)
        #expect(DockReplacementController.clamp(fine, into: usable) == fine)
    }

    /// Nobody wants their window twitching because it is two points over a line.
    @Test func aHairOverTheEdgeIsNotWorthMoving() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let barelyDifferent = CGRect(x: 2, y: 1, width: 800, height: 600)
        #expect(!DockReplacementController.isWorthMoving(from: frame, to: barelyDifferent))

        let clearlyDifferent = CGRect(x: 40, y: 0, width: 800, height: 600)
        #expect(DockReplacementController.isWorthMoving(from: frame, to: clearlyDifferent))
    }
}

@MainActor
@Suite("Keeping applications in the dock")
struct DockPinTests {
    private func makePreferences() -> Preferences {
        let suite = "dock.pin.tests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return Preferences(defaults: defaults)
    }

    /// The list starts empty and unseeded, which is a different thing from empty-by-choice: one
    /// means "take the Dock's arrangement", the other means "they removed everything".
    @Test func anUnseededListIsNotAnEmptyChoice() {
        let preferences = makePreferences()
        #expect(preferences.dockPins.isEmpty)
        #expect(preferences.dockPinsSeeded == false)

        preferences.dockPinsSeeded = true
        #expect(preferences.dockPins.isEmpty)
        #expect(preferences.dockPinsSeeded, "an empty list that was seeded stays empty")
    }

    @Test func pinsSurviveBeingWrittenAndRead() {
        let preferences = makePreferences()
        preferences.dockPins = ["com.apple.Safari", "com.apple.mail"]
        preferences.dockPinsSeeded = true

        let reread = Preferences(defaults: UserDefaults(suiteName: "dock.pin.tests") ?? .standard)
        #expect(reread.dockPins == ["com.apple.Safari", "com.apple.mail"], "order is the arrangement")
        #expect(reread.dockPinsSeeded)
    }

    /// Tiles are resolved from the identifier rather than a stored path, so an application that
    /// moved still opens.
    @Test func tilesResolveFromTheIdentifier() {
        let tiles = DockTileSource.pinnedTiles(identifiers: ["com.apple.Safari", "com.example.nothing"])
        #expect(tiles.count == 1, "an application that is not installed leaves no tile behind")
        #expect(tiles.first?.bundleIdentifier == "com.apple.Safari")
        #expect(tiles.first?.url != nil)
        #expect(tiles.first?.name.isEmpty == false)
    }
}
