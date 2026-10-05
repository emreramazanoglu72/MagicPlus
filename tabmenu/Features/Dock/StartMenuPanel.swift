//
//  StartMenuPanel.swift
//  MagicPlus
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// The panel behind the first button in the bar.
///
/// What a start menu is, reduced to what it is actually for: a search field, everything installed
/// in a grid, and the handful of commands that end the session. Nothing here is new machinery —
/// `AppLauncher` already enumerated the applications for the window switcher, so this is the same
/// list wearing a different shape.
@MainActor
final class StartMenuPanel: NSObject, NSWindowDelegate {
    @Observable
    @MainActor
    final class Model {
        var query = ""
        var apps: [LaunchableApp] = []
        /// Which of them are already open, so those can be offered first.
        var runningIdentifiers: Set<String> = []
        /// Highlighted by the arrow keys, launched by Return.
        var selection = 0
        /// The look of the bar this opened out of, so the two match. A panel that opens from a dark
        /// glass strip and is itself a different colour reads as somebody else's window.
        var style = DockStyle()

        /// Matches, with the applications that are already open at the front.
        ///
        /// One array rather than two, deliberately. The grid draws it in two sections and the arrow
        /// keys walk it as a single list, and both are indexing the same thing — two parallel lists
        /// reliably end up disagreeing about which tile Return will open.
        var results: [LaunchableApp] {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            let matches = trimmed.isEmpty
                ? apps
                : apps.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            let open = matches.filter { runningIdentifiers.contains($0.id) }
            guard !open.isEmpty else { return matches }
            return open + matches.filter { !runningIdentifiers.contains($0.id) }
        }

        /// How many entries at the front of `results` are running.
        ///
        /// Takes the array rather than reading `results` again: it is filtered from a few hundred
        /// applications, and asking for it twice per pass to answer one question about it is work
        /// nobody needs done.
        func openCount(in results: [LaunchableApp]) -> Int {
            results.prefix { runningIdentifiers.contains($0.id) }.count
        }
    }

    private let model = Model()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let outsideClicks = OutsideClickMonitor()
    /// The button this opened out of, so a click on it is left for the button to handle.
    private var anchorOnScreen: CGRect = .zero

    /// Six columns of tiles wide, and tall enough that a scroll is a scroll rather than a peephole.
    private static let size = CGSize(width: 600, height: 620)

    var isVisible: Bool { panel?.isVisible ?? false }

    /// - Parameters:
    ///   - anchor: The button's rectangle in Cocoa screen coordinates, so the panel opens out of
    ///     the thing that was clicked rather than in the middle of the screen.
    ///   - style: The bar's own look, which this wears too.
    func toggle(anchor: CGRect, style: DockStyle) {
        isVisible ? hide() : show(anchor: anchor, style: style)
    }

    func show(anchor: CGRect, style: DockStyle) {
        model.query = ""
        model.selection = 0
        model.apps = AppLauncher.installedApps()
        model.runningIdentifiers = DockTileSource.runningIdentifiers()
        model.style = style

        let panel = panel ?? makePanel()
        self.panel = panel
        anchorOnScreen = anchor
        position(panel, anchor: anchor, edge: style.edge)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyMonitor()
        outsideClicks.start(panel: panel, anchor: anchor) { [weak self] in self?.hide() }
    }

    func hide() {
        stopKeyMonitor()
        outsideClicks.stop()
        panel?.orderOut(nil)
    }

    // MARK: - Placement

    private func position(_ panel: NSPanel, anchor: CGRect, edge: DockStyle.Edge) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        else { return }
        let gap: CGFloat = 8
        var origin: CGPoint

        switch edge {
        case .bottom:
            origin = CGPoint(x: anchor.minX, y: anchor.maxY + gap)
        case .top:
            origin = CGPoint(x: anchor.minX, y: anchor.minY - Self.size.height - gap)
        }

        // Never off the screen it belongs to, whatever the anchor says.
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - Self.size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: StartMenuView(
            model: model,
            onLaunch: { [weak self] app in
                AppLauncher.launch(app)
                self?.hide()
            },
            onSession: { [weak self] command in
                self?.hide()
                SessionCommand.perform(command)
            }
        ))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Keyboard

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, isVisible else { return event }
            let results = model.results

            switch Int(event.keyCode) {
            case kVK_Escape:
                hide()
                return nil
            // A grid, so down means the next row rather than the next tile. Moving one at a time
            // through a hundred and fifty applications six across is not navigation.
            case kVK_DownArrow:
                move(by: StartMenuView.columnCount, in: results)
                return nil
            case kVK_UpArrow:
                move(by: -StartMenuView.columnCount, in: results)
                return nil
            // Only while the field is empty. Left and right belong to the caret the moment there
            // is something to move it through — taking them would mean a typo in a search could
            // not be gone back and fixed.
            case kVK_RightArrow where model.query.isEmpty:
                move(by: 1, in: results)
                return nil
            case kVK_LeftArrow where model.query.isEmpty:
                move(by: -1, in: results)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                guard results.indices.contains(model.selection) else { return nil }
                AppLauncher.launch(results[model.selection])
                hide()
                return nil
            default:
                return event
            }
        }
    }

    /// Moves the selection, clamped rather than wrapped.
    ///
    /// Clamped because the last row is usually short: a step that ran off the end and came back at
    /// the beginning would make the down arrow jump to the top of the list, which is not what
    /// anybody pressing it wants.
    private func move(by offset: Int, in results: [LaunchableApp]) {
        guard !results.isEmpty else { return }
        model.selection = min(max(model.selection + offset, 0), results.count - 1)
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// The commands that end a session.
///
/// Sleep and display sleep are `pmset`, which needs nothing granted. Log out, restart and shut down
/// go through System Events, which needs Automation — so they are offered, and if the permission is
/// refused macOS says so rather than this pretending it worked.
nonisolated enum SessionCommand: String, CaseIterable, Identifiable, Sendable {
    case sleep
    case lockScreen
    case logOut
    case restart
    case shutDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleep: String(localized: "Sleep", comment: "Start menu session command")
        case .lockScreen: String(localized: "Lock Screen", comment: "Start menu session command")
        case .logOut: String(localized: "Log Out…", comment: "Start menu session command")
        case .restart: String(localized: "Restart…", comment: "Start menu session command")
        case .shutDown: String(localized: "Shut Down…", comment: "Start menu session command")
        }
    }

    var symbolName: String {
        switch self {
        case .sleep: "moon.fill"
        case .lockScreen: "lock.fill"
        case .logOut: "rectangle.portrait.and.arrow.right"
        case .restart: "arrow.clockwise"
        case .shutDown: "power"
        }
    }

    static func perform(_ command: SessionCommand) {
        switch command {
        case .sleep:
            run("/usr/bin/pmset", ["sleepnow"])
        case .lockScreen:
            run("/usr/bin/pmset", ["displaysleepnow"])
        case .logOut:
            tellSystemEvents("log out")
        case .restart:
            tellSystemEvents("restart")
        case .shutDown:
            tellSystemEvents("shut down")
        }
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }

    private static func tellSystemEvents(_ verb: String) {
        run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to \(verb)"])
    }
}
