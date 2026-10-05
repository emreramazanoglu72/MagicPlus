//
//  DockReplacementController.swift
//  MagicPlus
//

import AppKit
import Observation
import SwiftUI
import os

/// Owns the dock this app draws, and the real Dock while ours is up.
///
/// Replacing the Dock means two responsibilities, and the second is the one that matters: getting
/// the real one out of the way, and giving it back. macOS offers no way to remove the Dock, so it
/// is set to hide itself with a reveal delay long enough that it never comes out — the same
/// mechanism every dock replacement uses. What it had before is written down first, and put back
/// when ours goes away.
///
/// Including after a crash. A force-quit while our dock was up would otherwise leave a Mac with no
/// Dock at all and no obvious way to get it back, so the saved state is checked on every launch:
/// if it is there and our dock is off, the real Dock is restored before anything else happens.
@Observable
@MainActor
final class DockReplacementController {
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Dock")

    /// What the view follows. The window is built once and reads this; nothing here replaces a
    /// view or moves a window in response to a mouse event.
    @ObservationIgnored let model = DockModel()

    /// One strip per display, keyed by the number macOS knows that display by.
    ///
    /// A single panel joined to every Space still only ever sits on one screen, so plugging in a
    /// monitor left the second one without a dock at all — not a missing refinement, a feature that
    /// is simply not there on that display.
    @ObservationIgnored private var panels: [Int: NSPanel] = [:]

    /// The strip the pointer is on, for the menus and panels that open out of an icon.
    ///
    /// Found by where the pointer is rather than threaded through every callback: all of them are
    /// click-driven, and the click that opened a menu is by definition on the screen the pointer is
    /// on. Falls back to any strip at all, for the keyboard paths that have no pointer.
    private var panelUnderPointer: NSPanel? {
        let location = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }),
           let panel = panels[screen.deviceNumber] {
            return panel
        }
        return panels.values.first
    }
    /// Guards against repositioning inside a layout pass, and against doing it twice in a row.
    @ObservationIgnored private var pendingLayout: Task<Void, Never>?
    /// Window titles change without any notification saying so, so the list is re-read on a slow
    /// timer — only while the layout that shows them is up.
    @ObservationIgnored private var windowTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var distributedObserver: NSObjectProtocol?

    private nonisolated static let realDockKey = "dock.realDockState"
    private nonisolated static let dockDomain = "com.apple.dock" as CFString

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Lifecycle

    /// Brings the dock up or takes it down to match the preferences, and rescues a Mac whose Dock
    /// was left hidden by a crash.
    func updateState() {
        guard preferences.isEnabled(.dock), preferences.isCustomDockEnabled else {
            tearDown()
            restoreRealDock()
            return
        }

        model.style = preferences.dockStyle
        model.showsAgent = preferences.isAgentEnabled
        // Starts parked when it hides itself, or it would sit there until first hovered.
        model.isAutoHidden = preferences.dockStyle.autoHides
        // Read once now, in the background, so the first right-click on an icon already knows
        // which applications open at login.
        LoginItems.refreshIfStale()
        // Before hiding it: taking its arrangement means reading its preferences, and restarting
        // the Dock first is how that read came back empty.
        seedPinsIfNeeded()
        hideRealDock()
        reloadTiles()
        refreshWindows()
        refreshBar()
        ensurePanel()
        observe()
        updateWindowTimer()
        installTerminationHandlers()
    }

    @ObservationIgnored private var terminationSignals: [DispatchSourceSignal] = []

    /// Puts the real Dock back when the app is killed rather than quit.
    ///
    /// `applicationWillTerminate` does not run for a signal, and this app hides the system Dock and
    /// parks it on another edge to do its job. Killed with `kill` or `pkill` — or by anything that
    /// sends `SIGTERM` — it left the Mac with no Dock at all and no visible way to get one back.
    /// That happened, on this machine, and had to be undone by hand.
    ///
    /// A `DispatchSource` rather than a `signal()` handler on purpose: a signal handler may only
    /// call a short list of async-signal-safe functions, and none of what restoring the Dock needs
    /// is on it. A dispatch source runs the work as ordinary code on a queue instead.
    ///
    /// `SIGKILL` cannot be caught by anything, so `recoverIfNeeded()` at the next launch stays the
    /// backstop for that one.
    private func installTerminationHandlers() {
        guard terminationSignals.isEmpty else { return }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            // The default action has to go, or the process dies before the source ever runs.
            signal(number, SIG_IGN)
            // Not the main queue, and this matters more than it looks. Ignoring the signal removes
            // the only thing that was guaranteed to end the process, so whatever replaces it has to
            // run *without* the main thread's cooperation — the main thread walks the Accessibility
            // tree on a timer and can be busy for hundreds of milliseconds at a stretch. Handled on
            // `.main`, a `pkill` arriving in one of those windows would be ignored and then never
            // acted on: an app that cannot be killed at all, which is worse than the parked Dock
            // this exists to prevent.
            let source = DispatchSource.makeSignalSource(signal: number, queue: Self.terminationQueue)
            source.setEventHandler {
                // A hard deadline either way. If putting the Dock back hangs — it talks to
                // preferences and to another process — the app still goes away.
                Self.terminationQueue.asyncAfter(deadline: .now() + 2) { exit(0) }
                Self.restoreRealDockWithoutTheMainThread()
                exit(0)
            }
            source.resume()
            terminationSignals.append(source)
        }
    }

    private static let terminationQueue = DispatchQueue(label: "com.tabmenu.dock.termination")

    /// Puts the Dock's own settings back and restarts it, using nothing that needs the main actor.
    ///
    /// `CFPreferences` is safe from any thread and `killall` is a subprocess, so this holds whatever
    /// the rest of the app is doing. The saved state is read through `UserDefaults`, which is also
    /// thread-safe; an absent one means there is nothing of ours to undo.
    private nonisolated static func restoreRealDockWithoutTheMainThread() {
        guard let data = UserDefaults.standard.data(forKey: realDockKey) else { return }
        let state = (try? JSONDecoder().decode(RealDockState.self, from: data)) ?? RealDockState()

        CFPreferencesSetAppValue("autohide" as CFString, state.autohide.map { NSNumber(value: $0) }, dockDomain)
        CFPreferencesSetAppValue("autohide-delay" as CFString, state.autohideDelay.map { NSNumber(value: $0) }, dockDomain)
        CFPreferencesSetAppValue("orientation" as CFString, state.orientation.map { $0 as NSString }, dockDomain)
        CFPreferencesAppSynchronize(dockDomain)
        UserDefaults.standard.removeObject(forKey: realDockKey)

        // `NSRunningApplication` is AppKit and belongs to the main thread; a subprocess does not.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Called at launch before anything is shown: a saved real-Dock state with our dock switched
    /// off can only mean the app went away without putting it back.
    func recoverIfNeeded() {
        guard !(preferences.isEnabled(.dock) && preferences.isCustomDockEnabled) else { return }
        guard UserDefaults.standard.object(forKey: Self.realDockKey) != nil else { return }
        logger.notice("restoring the real Dock left hidden by a previous run")
        restoreRealDock()
    }

    /// Called when the settings pane edits the style. The view follows the model on its own; only
    /// the window's size and place are ours to update.
    func styleChanged() {
        guard !panels.isEmpty else {
            model.style = preferences.dockStyle
            return
        }
        // The style the view uses is worked out in `layOut`, which is the only place with a screen
        // to measure against.
        refreshWindows()
        updateWindowTimer()
        scheduleLayout()
    }

    private func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        distributedObserver = nil
        pendingLayout?.cancel()
        pendingLayout = nil
        windowTimer?.invalidate()
        windowTimer = nil
        // A dock that is gone reserves nothing.
        DockReservation.shared.clearAll()
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
    }

    // MARK: - The real Dock

    /// What the Dock's own settings were before we touched them. `nil` for a value means the key
    /// was not there at all, which is a different thing from `false` and has to be restored as
    /// absence rather than as a decision.
    private nonisolated struct RealDockState: Codable {
        var autohide: Bool?
        var autohideDelay: Double?
        var orientation: String?
    }

    private func hideRealDock() {
        // Saving happens once — a second save would record the hidden state as the thing to restore
        // — but the hiding itself has to be applied whenever it is not already in force. Guarding
        // both on the same condition meant that a Dock someone had un-hidden by hand stayed
        // visible underneath ours for ever after.
        if UserDefaults.standard.object(forKey: Self.realDockKey) == nil {
            saveRealDockState()
        }

        // Hiding it is not enough on its own. A hidden Dock still reveals itself when the pointer
        // reaches the edge it lives on, and `autohide-delay` turned out not to hold it back — with
        // our own bar along the bottom, every trip to that bar brought the Dock out from under it.
        // So it is also moved to the edge ours is not on, where nothing sends the pointer by
        // accident. Both the hiding and the move are undone together.
        let wanted = Self.parkingEdge(for: preferences.dockStyle)
        let hidden = CFPreferencesCopyAppValue("autohide" as CFString, Self.dockDomain) as? Bool ?? false
        let delay = CFPreferencesCopyAppValue("autohide-delay" as CFString, Self.dockDomain) as? Double ?? 0
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, Self.dockDomain) as? String
        guard !(hidden && delay >= 100 && orientation == wanted) else { return }

        CFPreferencesSetAppValue("autohide" as CFString, NSNumber(value: true), Self.dockDomain)
        CFPreferencesSetAppValue("autohide-delay" as CFString, NSNumber(value: 1000.0), Self.dockDomain)
        CFPreferencesSetAppValue("orientation" as CFString, wanted as NSString, Self.dockDomain)
        CFPreferencesAppSynchronize(Self.dockDomain)
        restartRealDock()
        logger.notice("real Dock hidden and parked on the \(wanted, privacy: .public) edge")
    }

    private func saveRealDockState() {
        let state = RealDockState(
            autohide: CFPreferencesCopyAppValue("autohide" as CFString, Self.dockDomain) as? Bool,
            autohideDelay: CFPreferencesCopyAppValue("autohide-delay" as CFString, Self.dockDomain) as? Double,
            orientation: CFPreferencesCopyAppValue("orientation" as CFString, Self.dockDomain) as? String
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.realDockKey)
        }
    }

    /// The edge to park the system Dock on: the one furthest from ours, so the pointer never goes
    /// there on the way to something else.
    static func parkingEdge(for style: DockStyle) -> String {
        // Always the right: our bar takes the bottom or the top, and the right is the edge nothing
        // sends the pointer to on the way to something else.
        switch style.edge {
        case .bottom, .top: "right"
        }
    }

    func restoreRealDock() {
        guard let data = UserDefaults.standard.data(forKey: Self.realDockKey) else { return }
        let state = (try? JSONDecoder().decode(RealDockState.self, from: data)) ?? RealDockState()

        CFPreferencesSetAppValue(
            "autohide" as CFString,
            state.autohide.map { NSNumber(value: $0) },
            Self.dockDomain
        )
        CFPreferencesSetAppValue(
            "autohide-delay" as CFString,
            state.autohideDelay.map { NSNumber(value: $0) },
            Self.dockDomain
        )
        CFPreferencesSetAppValue(
            "orientation" as CFString,
            state.orientation.map { $0 as NSString },
            Self.dockDomain
        )
        CFPreferencesAppSynchronize(Self.dockDomain)
        UserDefaults.standard.removeObject(forKey: Self.realDockKey)
        restartRealDock()
        logger.notice("real Dock restored")
    }

    private func restartRealDock() {
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
            application.terminate()
        }
    }

    // MARK: - Contents

    /// Takes the system Dock's arrangement once, so the dock opens looking like what was there.
    private func seedPinsIfNeeded() {
        guard !preferences.dockPinsSeeded else { return }

        let identifiers = DockTileSource.systemDockIdentifiers()
        // An empty answer is not an arrangement, it is a failed read — the Dock had just been
        // restarted the first time this ran, and its preferences came back with nothing. Marking
        // that as seeded would have left the dock permanently empty with no way to notice.
        guard !identifiers.isEmpty else {
            logger.notice("the system Dock listed nothing; leaving the pins unseeded")
            return
        }

        preferences.dockPins = identifiers
        preferences.dockPinsSeeded = true
        logger.notice("seeded \(identifiers.count, privacy: .public) pins from the system Dock")
    }

    func reloadTiles() {
        seedPinsIfNeeded()
        // Our own list is the list. The folders on the right still come from the Dock, which is
        // where they live and where nothing else can put them.
        let pinned = DockTileSource.pinnedTiles(identifiers: preferences.dockPins)
            + DockTileSource.pinnedTiles().filter { !$0.isApplication }
        let running = DockTileSource.runningIdentifiers()
        var result = pinned.map { tile -> DockTile in
            var tile = tile
            if let identifier = tile.bundleIdentifier {
                tile.isRunning = running.contains(identifier)
            }
            return tile
        }

        if model.style.showsRunningApps {
            let extras = DockTileSource.runningTiles(excluding: pinned)
            if !extras.isEmpty {
                result.append(DockTile(id: "divider.running", kind: .separator, url: nil, name: ""))
                result.append(contentsOf: extras)
            }
        }

        result.append(DockTile(id: "divider.trash", kind: .separator, url: nil, name: ""))
        result.append(DockTile(
            id: "trash",
            kind: .trash,
            url: URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"),
            name: String(localized: "Trash", comment: "Dock tile")
        ))

        guard result != model.tiles else { return }
        let countChanged = result.count != model.tiles.count
        model.tiles = result
        // Only a change in how many tiles there are changes how big the window has to be. A tile
        // that merely started running does not.
        // How many tiles there are decides how big they can be, so a change in count means the
        // fit and the window have to be worked out again.
        if countChanged { scheduleLayout() }
    }

    // MARK: - The window

    /// A strip on every screen, and none left over from a screen that has gone.
    private func ensurePanel() {
        let wanted = Set(NSScreen.screens.map(\.deviceNumber))

        for (number, panel) in panels where !wanted.contains(number) {
            panel.orderOut(nil)
            panels.removeValue(forKey: number)
        }
        for screen in NSScreen.screens where panels[screen.deviceNumber] == nil {
            panels[screen.deviceNumber] = makePanel()
        }

        scheduleLayout()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // The level the real Dock uses, so windows go under it and menus stay over it.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))

        let hostingView = NSHostingView(rootView: makeRootView())
        // The window's size is ours to decide. Letting the hosting view push its own idea of the
        // right size back into the window is what turns a magnifying dock into a resize loop.
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        panel.orderFront(nil)
        return panel
    }

    /// The one shape the dock takes. It used to pick between three; the other two could not be
    /// reached from anywhere in the app, and they are gone.
    private func makeRootView() -> AnyView {
        AnyView(
            DockStripView(
                model: model,
                onStart: { [weak self] frame in self?.showStartMenu(anchoredAt: frame) },
                onOpenTile: { [weak self] tile, frame in self?.open(tile, anchoredAt: frame) },
                onMedia: { [weak self] command in self?.perform(command) },
                onVolume: { [weak self] frame in self?.showVolume(anchoredAt: frame) },
                onSetEdge: { [weak self] edge in self?.change { $0.edge = edge } },
                onOpenSettings: { SettingsWindow.open() },
                onDisable: { [weak self] in
                    self?.preferences.isCustomDockEnabled = false
                    self?.updateState()
                },
                onHoverIcon: { [weak self] hovered in self?.hover(hovered) },
                onDrop: { [weak self] tile, urls in self?.accept(urls, on: tile) ?? false },
                onShowDesktop: { [weak self] in
                    ShowDesktop.toggle()
                    self?.model.isDesktopShowing = ShowDesktop.isShowingDesktop
                },
                onDropOnAgent: { [weak self] urls in
                    guard let self, let panel = panelUnderPointer, !urls.isEmpty else { return false }
                    onAcceptFiles?(urls, screenRect(of: .zero, in: panel), model.style)
                    return true
                },
                onHoverStrip: { [weak self] isOver in self?.stripHoverChanged(isOver) },
                onAgent: { [weak self] frame in self?.showAgent(anchoredAt: frame) },
                menu: { [weak self] tile, windows in
                    self?.makeMenu(for: tile, windows: windows) ?? DockTileMenu.empty(for: tile)
                }
            )
        )
    }

    /// Second click on a window that is already in front puts it away, which is what a row in a
    /// sidebar is expected to do.
    private func toggleMinimised(_ window: SwitchableWindow) {
        AXUIElementSetAttributeValue(
            window.element,
            kAXMinimizedAttribute as CFString,
            (!window.isMinimized) as CFBoolean
        )
        refreshWindows()
    }

    private func quitApplication(of window: SwitchableWindow) {
        NSRunningApplication(processIdentifier: window.processIdentifier)?.terminate()
        refreshWindows()
    }

    @ObservationIgnored private let startMenu = StartMenuPanel()
    @ObservationIgnored private let volumePanel = VolumePanel()

    /// Edits the style in place, from the bar's own menu.
    private func change(_ edit: (inout DockStyle) -> Void) {
        var style = preferences.dockStyle
        edit(&style)
        preferences.dockStyle = style
        styleChanged()
    }

    @ObservationIgnored private var parkTask: Task<Void, Never>?

    /// Whether something the bar opened is still on screen. A strip that parks itself while its own
    /// menu is standing open takes the menu's anchor away with it.
    @ObservationIgnored var isAgentPanelVisible: (() -> Bool)?

    private var hasSomethingOpen: Bool {
        startMenu.isVisible || volumePanel.isVisible || folderStack.isVisible
            || (isAgentPanelVisible?() ?? false)
    }

    /// The pointer arriving at or leaving the strip.
    ///
    /// Revealing is immediate — the pointer is already there — and parking waits, because a pointer
    /// crossing the bar on its way somewhere else is not a decision to dismiss it.
    private func stripHoverChanged(_ isOver: Bool) {
        guard preferences.dockStyle.autoHides else { return }
        parkTask?.cancel()

        if isOver {
            guard model.isAutoHidden else { return }
            model.isAutoHidden = false
            scheduleLayout()
            return
        }

        parkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, !hasSomethingOpen, !model.isAutoHidden else { return }
            model.isAutoHidden = true
            scheduleLayout()
        }
    }

    /// Called when the setting changes, so switching it off brings the bar back at once.
    func autoHideChanged() {
        parkTask?.cancel()
        model.isAutoHidden = preferences.dockStyle.autoHides
        scheduleLayout()
    }

    /// Set by the composition root: the chat panel is the agent's, not the dock's.
    @ObservationIgnored var onShowAgent: ((CGRect, DockStyle) -> Void)?
    /// Files dropped on the assistant's button, for the agent to take and the panel to open on.
    @ObservationIgnored var onAcceptFiles: (([URL], CGRect, DockStyle) -> Void)?

    /// Called when the assistant is switched on or off, so the button appears or goes without a
    /// relaunch.
    func agentAvailabilityChanged() {
        model.showsAgent = preferences.isAgentEnabled
    }

    private func showAgent(anchoredAt frame: CGRect) {
        guard let panel = panelUnderPointer else { return }
        onShowAgent?(screenRect(of: frame, in: panel), model.style)
    }

    private func showVolume(anchoredAt frame: CGRect) {
        guard let panel = panelUnderPointer else { return }
        volumePanel.toggle(anchor: screenRect(of: frame, in: panel), edge: model.style.edge)
    }

    /// Opens the start menu out of the button that was clicked.
    ///
    /// The frame arrives in the panel's coordinates, top-left origin, and the menu needs Cocoa
    /// screen coordinates — the same conversion the previews need, for the same reason.
    private func showStartMenu(anchoredAt frame: CGRect) {
        guard let panel = panelUnderPointer else { return }
        startMenu.toggle(anchor: screenRect(of: frame, in: panel), style: model.style)
    }

    /// SwiftUI reports a frame in the window's own coordinates, top-left origin. Everything that
    /// opens beside it needs Cocoa screen coordinates, bottom-left origin.
    private func screenRect(of frame: CGRect, in panel: NSPanel) -> CGRect {
        CGRect(
            x: panel.frame.minX + frame.minX,
            y: panel.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Set by the composition root so previews can hang off our own icons.
    @ObservationIgnored var previews: DockPreviewController?

    /// Shows or hides the window previews for the icon under the pointer.
    ///
    /// The frame arrives in the panel's own coordinates — top-left origin, as SwiftUI reports it —
    /// and has to be handed on in Cocoa screen coordinates, which is the conversion this does.
    private func hover(_ hovered: (tile: DockTile, frame: CGRect)?) {
        guard let previews else { return }
        guard let hovered, let panel = panelUnderPointer, let identifier = hovered.tile.bundleIdentifier,
              let application = NSRunningApplication
                .runningApplications(withBundleIdentifier: identifier).first
        else {
            previews.dismissForCustomDock()
            return
        }

        let frame = CGRect(
            x: panel.frame.minX + hovered.frame.minX,
            y: panel.frame.maxY - hovered.frame.maxY,
            width: hovered.frame.width,
            height: hovered.frame.height
        )
        previews.presentForCustomDock(
            processIdentifier: application.processIdentifier,
            title: hovered.tile.name,
            iconFrame: frame,
            edge: model.style.edge
        )
    }

    /// Builds the right-click menu for one icon. Every answer in it — whether the app is kept,
    /// whether it opens at login, which of its windows are open — needs something only the
    /// controller has, so the view is handed a finished menu rather than ten more callbacks.
    func makeMenu(for tile: DockTile, windows: [SwitchableWindow]) -> DockTileMenu {
        DockTileMenu(
            tile: tile,
            windows: windows,
            isPinned: isPinned(tile),
            opensAtLogin: opensAtLogin(tile),
            onOpen: { [weak self] in self?.open(tile) },
            onFocusWindow: { window in WindowLister.focus(window) },
            onNewWindow: { [weak self] in self?.openNewWindow(tile) },
            onTogglePinned: { [weak self] in self?.togglePinned(tile) },
            onToggleOpenAtLogin: { [weak self] in self?.toggleOpenAtLogin(tile) },
            onReveal: {
                guard let url = tile.url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            onShowAllWindows: { [weak self] in self?.showAllWindows(tile) },
            onHide: { [weak self] in self?.hideApplication(tile) },
            onQuit: { [weak self] in self?.quit(tile) },
            onForceQuit: { [weak self] in self?.forceQuit(tile) }
        )
    }

    // MARK: - Keeping and removing

    func isPinned(_ tile: DockTile) -> Bool {
        guard let identifier = tile.bundleIdentifier else { return false }
        return preferences.dockPins.contains(identifier)
    }

    /// What the Dock's own "Keep in Dock" does, on our list instead of Apple's.
    func togglePinned(_ tile: DockTile) {
        guard let identifier = tile.bundleIdentifier else { return }
        var pins = preferences.dockPins
        if let index = pins.firstIndex(of: identifier) {
            pins.remove(at: index)
        } else {
            pins.append(identifier)
        }
        preferences.dockPins = pins
        reloadTiles()
    }

    func hideApplication(_ tile: DockTile) {
        runningApplication(for: tile)?.hide()
    }

    func showAllWindows(_ tile: DockTile) {
        runningApplication(for: tile)?.activate(options: [.activateAllWindows])
    }

    func forceQuit(_ tile: DockTile) {
        runningApplication(for: tile)?.forceTerminate()
    }

    /// Adds or removes a login item through System Events, which is the scriptable way macOS
    /// offers for applications other than this one — there is no public API for putting somebody
    /// else's app in the login list.
    func toggleOpenAtLogin(_ tile: DockTile) {
        guard let url = tile.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let script = LoginItems.contains(name)
            ? "tell application \"System Events\" to delete login item \"\(name)\""
            : "tell application \"System Events\" to make login item at end with properties {path:\"\(url.path)\", hidden:false}"
        // Off the main thread: this is the same subprocess the reading uses, and a menu item that
        // wedges the interface for a second is a menu item nobody uses twice. The list is re-read
        // afterwards so the checkmark tells the truth next time the menu opens.
        DispatchQueue.global(qos: .userInitiated).async {
            LoginItems.run(script)
            LoginItems.invalidate()
        }
    }

    func opensAtLogin(_ tile: DockTile) -> Bool {
        guard let url = tile.url else { return false }
        return LoginItems.contains(url.deletingPathExtension().lastPathComponent)
    }

    private func runningApplication(for tile: DockTile) -> NSRunningApplication? {
        guard let identifier = tile.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
    }

    /// A second window of an application that is already running, which is what the Dock's own
    /// "New Window" does.
    private func openNewWindow(_ tile: DockTile) {
        guard let url = tile.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Set by the composition root: the queue is the downloads module's, and the bar only reports it.
    @ObservationIgnored weak var downloads: DownloadStore?

    /// Set by the composition root so the bar's own button can open the popover.
    @ObservationIgnored var onOpenPanel: (() -> Void)?

    private func perform(_ command: DockStripView.MediaCommand) {
        // The source travels with what is playing, so there is nothing to look up.
        guard let source = model.nowPlaying?.source else { return }
        switch command {
        case .previous: MediaController.previousTrack(source)
        case .playPause: MediaController.playPause(source)
        case .next: MediaController.nextTrack(source)
        }
        refreshNowPlaying(force: true)
    }

    /// The three things only the bar needs: what is in front, what is playing, and the counts the
    /// Dock is drawing. Read on the same slow timer as the window list, and only for that layout.
    func refreshBar() {
        // The counts belong on every layout, and most of all on the plain dock of icons — which is
        // exactly where they were missing, because this returned early for anything but the bar.
        let badges = DockItemLister.badges()
        if badges != model.badges { model.badges = badges }

        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            // Assigned only when they change, and that is not tidiness. Every one of these is
            // observed by the strip, and an observable property assigned its own value invalidates
            // the whole view graph exactly as hard as a real change does — twenty-six icons, their
            // colours and the layout, re-evaluated every tick for nothing.
            let identifier = front.bundleIdentifier ?? ""
            if model.frontmostBundleIdentifier != identifier {
                model.frontmostBundleIdentifier = identifier
                model.frontmostName = front.localizedName ?? ""
                // Compared by application rather than by image: `NSImage` has no equality worth
                // the name, so the application changing is the only honest signal that the icon has.
                model.frontmostIcon = front.icon
            }

            // From the list the tick already has, rather than a sweep of its own.
            let title = model.windows
                .first { $0.processIdentifier == front.processIdentifier }?.title ?? ""
            if model.frontmostWindowTitle != title { model.frontmostWindowTitle = title }
        }

        refreshNowPlaying()

        let progress = downloads?.overallProgress
        if progress != model.downloadProgress { model.downloadProgress = progress }
    }

    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    @ObservationIgnored private var lastMediaRead = Date.distantPast

    /// How often the strip asks what is playing.
    ///
    /// Much slower than the tick the rest of the bar runs on. Asking a browser what tab it is on
    /// means an `osascript` subprocess and a few hundred milliseconds of the browser's attention,
    /// and the notch is already asking the same question on its own schedule — two pollers at a
    /// second and a half apiece is most of a core between them, spent on a track title that changes
    /// every few minutes. Pressing play or skip does not wait for this.
    private static let mediaInterval: TimeInterval = 5

    /// Reads what is playing, off the main thread.
    ///
    /// Done on the main thread — which is how this was written — the subprocess above is a few
    /// hundred milliseconds the whole interface spends frozen, on every tick. The notch's reading
    /// has always been detached; this one was not.
    ///
    /// One at a time: a reading that outlives its tick must not have another piled on top of it.
    ///
    /// - Parameter force: Skips the interval, for a transport button that has just been pressed and
    ///   wants the bar to say so.
    private func refreshNowPlaying(force: Bool = false) {
        guard mediaTask == nil else { return }
        guard force || Date().timeIntervalSince(lastMediaRead) >= Self.mediaInterval else { return }
        lastMediaRead = Date()

        mediaTask = Task { [weak self] in
            let playing = await Task.detached(priority: .utility) {
                MediaController.nowPlaying()
            }.value

            guard let self else { return }
            mediaTask = nil
            if playing != model.nowPlaying { model.nowPlaying = playing }
            updateArtwork(for: playing)
        }
    }

    @ObservationIgnored private var artworkURL: URL?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?

    /// Fetches the cover of whatever is playing, once per track rather than once per tick.
    ///
    /// The strip draws the source's own glyph until this arrives and goes straight back to it when
    /// playback stops — a cover that outlived the track it belongs to is worse than no cover, since
    /// it is a confident answer to the wrong question.
    private func updateArtwork(for playing: NowPlaying?) {
        guard let url = playing?.artworkURL else {
            artworkTask?.cancel()
            artworkTask = nil
            artworkURL = nil
            if model.nowPlayingArtwork != nil { model.nowPlayingArtwork = nil }
            return
        }

        guard url != artworkURL else { return }
        artworkURL = url
        model.nowPlayingArtwork = nil
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data)
            else { return }
            // The track may have changed while this was in flight.
            guard let self, self.artworkURL == url else { return }
            self.model.nowPlayingArtwork = image
        }
    }

    /// Moves windows out of the strip the dock occupies.
    ///
    /// This is what "reserves screen space" has to mean for a third party. Only the Dock and the
    /// menu bar can shrink the area macOS hands to windows, so a strip of ours is a strip other apps
    /// know nothing about — they open over it and their content disappears underneath. Subtracting
    /// it from this app's own placement was the honest half of the answer; this is the other half:
    /// a window found sitting in the strip is nudged out of it.
    ///
    /// Deliberately conservative. Only an overlap worth noticing is corrected, so a window a hair
    /// over the edge is left alone rather than jittering, and only windows that can be moved move —
    /// the rest simply refuse and are left as they are.
    func enforceReservation() {
        let style = preferences.dockStyle
        guard style.reservesSpace, style.fillsEdge, !style.autoHides else { return }

        let ownProcess = ProcessInfo.processInfo.processIdentifier
        for window in model.windows {
            guard window.processIdentifier != ownProcess, !window.isMinimized else { continue }
            guard let frame = window.frame else { continue }
            guard let screen = NSScreen.containing(accessibilityPoint: CGPoint(x: frame.midX, y: frame.midY))
                ?? NSScreen.main
            else { continue }

            // A full-screen window belongs to the system, not to us. This shrank one by the
            // height of the strip, once every tick, for as long as you stayed on that Space —
            // fighting macOS for control of the Space and losing noisily each time.
            guard !Self.isFullScreen(window, onDisplayOfSize: screen.frame.size, frame: frame)
            else { continue }

            let usable = screen.accessibilityVisibleFrame
            let corrected = Self.clamp(frame, into: usable)
            guard Self.isWorthMoving(from: frame, to: corrected) else { continue }

            let accessibility = AccessibilityWindow(
                element: window.element,
                processIdentifier: window.processIdentifier,
                applicationName: window.applicationName,
                title: window.title
            )
            _ = accessibility.setFrame(corrected)
        }
    }

    /// Whether a window is big enough to be a full-screen one.
    ///
    /// The cheap half of the test, and the one worth having on its own: only a window covering its
    /// whole display can be full screen, and a zoomed window stops at `visibleFrame`, which is
    /// shorter by the menu bar. Sizes rather than origins, because the window's frame is in
    /// Accessibility coordinates and the screen's is in Cocoa's — they measure the same rectangle
    /// from opposite corners, and only the size means the same thing in both.
    static func coversWholeDisplay(_ frame: CGSize, display: CGSize) -> Bool {
        frame.width >= display.width - 1 && frame.height >= display.height - 1
    }

    /// Whether this is a native full-screen window.
    ///
    /// Geometry first: asking Accessibility about every window on every tick would cost more than
    /// the enforcement it guards, and only a window covering its whole display is a candidate. A
    /// window that covers the display and will not answer is left alone — leaving a window where it
    /// is, is always safer than moving one that the system is holding.
    private static func isFullScreen(
        _ window: SwitchableWindow,
        onDisplayOfSize display: CGSize,
        frame: CGRect
    ) -> Bool {
        guard coversWholeDisplay(frame.size, display: display) else { return false }

        AXUIElementSetMessagingTimeout(window.element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window.element, "AXFullScreen" as CFString, &value) == .success
        else { return true }
        return (value as? Bool) ?? true
    }

    /// Fits a rectangle inside another, shrinking it only when it cannot be moved to fit.
    static func clamp(_ frame: CGRect, into area: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(result.width, area.width)
        result.size.height = min(result.height, area.height)
        result.origin.x = min(max(result.minX, area.minX), area.maxX - result.width)
        result.origin.y = min(max(result.minY, area.minY), area.maxY - result.height)
        return result
    }

    /// Whether the correction is big enough to be worth imposing on someone.
    static func isWorthMoving(from frame: CGRect, to corrected: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(frame.minX - corrected.minX) > tolerance
            || abs(frame.minY - corrected.minY) > tolerance
            || abs(frame.width - corrected.width) > tolerance
            || abs(frame.height - corrected.height) > tolerance
    }

    /// Reads the open windows for the layout that lists them.
    ///
    /// Only when that layout is showing: enumerating every window of every application over the
    /// Accessibility API is not free, and a dock of icons has no use for the answer.
    /// The open windows, once per tick, for everything that needs them.
    ///
    /// It used to answer only for the sidebar layout and hand back an empty list otherwise — and
    /// the sidebar is gone, so the list was *always* empty. That silently emptied the window titles
    /// out of every icon's right-click menu, which is the first thing a right-click on a running
    /// app is reaching for.
    ///
    /// One sweep, not two: keeping windows out of the reserved strip used to take its own, so every
    /// tick walked the whole Accessibility tree twice for the same answer.
    func refreshWindows() {
        let windows = WindowLister.switchableWindows()
        guard windows != model.windows else { return }
        model.windows = windows
    }

    /// Moves and sizes the window, never synchronously.
    ///
    /// A frame change during AppKit's display cycle throws — the crash this replaced was exactly
    /// that, from a hover handler. Hopping to the next turn of the run loop puts the change safely
    /// outside any layout pass, and collapsing repeats keeps a burst of preference edits to one
    /// move.
    ///
    /// Also called on the ordinary tick, and that is not belt and braces. Screen parameters are
    /// what this measures against, and `didChangeScreenParameters` arrives while the Dock is still
    /// moving out of the way rather than after it has: the bar came up 1632 points wide and 48
    /// above the bottom of an 1800-point screen, measured against a `visibleFrame` that was true
    /// for about a second. Nothing posts a second notification once it settles. `layOut` returns
    /// immediately when the frame it computes is the frame the panel already has, so asking every
    /// tick costs nothing and answers every version of this — whatever moved, and whenever.
    private func scheduleLayout() {
        pendingLayout?.cancel()
        pendingLayout = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            for (number, panel) in panels {
                guard let screen = NSScreen.screens.first(where: { $0.deviceNumber == number })
                else { continue }
                layOut(panel, on: screen)
            }
        }
    }

    /// Gets out of the way of a full-screen application.
    ///
    /// The system Dock hides itself when something goes full screen; ours sat on top, over the
    /// video. A window at the Dock's level joined to every Space will do that unless it is told
    /// otherwise, and being told otherwise is a matter of noticing.
    func updateFullScreenVisibility() {
        guard !panels.isEmpty else { return }
        // One answer for every screen: full screen and Mission Control are about what is in front,
        // not about which display it is on.
        let covered = Self.frontmostIsFullScreen() || Self.systemOverviewIsShowing()
        for panel in panels.values { setHidden(covered, on: panel) }
    }

    /// Hides the strip without taking the window out of the window server.
    ///
    /// This used `orderOut` and `orderFront`, and for a window joined to every Space that is the
    /// wrong pair: bringing it back means re-adding it to all of them, and doing that in the middle
    /// of a three-finger swipe is what made the bar vanish and then turn up late. Alpha is instant
    /// and the window never leaves.
    private func setHidden(_ hidden: Bool, on panel: NSPanel) {
        let alpha: CGFloat = hidden ? 0 : 1
        guard panel.alphaValue != alpha else { return }
        panel.alphaValue = alpha
        // An invisible strip that still swallowed clicks along the bottom of a full-screen video
        // would be worse than a visible one.
        panel.ignoresMouseEvents = hidden
    }

    /// Whether Mission Control, Launchpad or App Exposé is on screen.
    ///
    /// All three are drawn by `Dock.app`, and none of them changes which application is frontmost —
    /// measured: swiping into Mission Control leaves `frontmostApplication` exactly where it was,
    /// so the obvious signal is not a signal. What does change is the Dock's own windows: at rest
    /// it owns one, the desktop picture, far below everything; while any of the three is up it owns
    /// several covering the screen at the level a dock lives at.
    ///
    /// Worth hiding for, because macOS draws the real Dock over all three whatever its settings
    /// say — parked and hidden included — so this is the one moment two docks are on screen at once.
    static func systemOverviewIsShowing() -> Bool {
        guard let screen = NSScreen.main else { return false }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

        for window in list {
            guard window[kCGWindowOwnerName as String] as? String == "Dock" else { continue }
            guard (window[kCGWindowLayer as String] as? Int ?? -1) >= 0 else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"]
            else { continue }
            // Big enough to be an overview rather than the Dock itself.
            if width > screen.frame.width * 0.6, height > screen.frame.height * 0.5 { return true }
        }
        return false
    }

    /// Whether the application in front has a window filling a whole screen with no menu bar
    /// showing, which is what native full screen looks like from the outside.
    static func frontmostIsFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }

        let element = AXUIElementCreateApplication(front.processIdentifier)
        // This question gets asked in the middle of a Space animation, and the default timeout for
        // an application that is slow to answer is six seconds. Nothing about a dock is worth
        // holding a swipe up for.
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value.map({ $0 as! AXUIElement })
        else { return false }

        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           let flag = fullScreen as? Bool {
            return flag
        }
        return false
    }

    /// Roughly how much of the strip is not icons.
    ///
    /// An estimate, on purpose. Measuring it for real would mean laying the view out before
    /// deciding how big to lay it out, and it only has to be close enough to keep the clock on the
    /// screen — being twenty points pessimistic costs a point of icon size, being wrong the other
    /// way costs the clock.
    private static func roomTheBarNeedsBesidesIcons(playing: Bool) -> CGFloat {
        let ourButton: CGFloat = 60
        let applicationInFront: CGFloat = 240
        let binVolumeAndClock: CGFloat = 150
        let playback: CGFloat = playing ? 300 : 0
        let breathingRoom: CGFloat = 80
        return ourButton + applicationInFront + binVolumeAndClock + playback + breathingRoom
    }

    /// Places one strip on one screen.
    ///
    /// The screen is passed in rather than read from `panel.screen`, which is the only way this can
    /// be right: a parked strip is mostly off its display and `panel.screen` answers accordingly, so
    /// a bar that had auto-hidden would be laid out against the wrong screen — or none.
    private func layOut(_ panel: NSPanel, on screen: NSScreen) {
        let requested = preferences.dockStyle
        let layout = DockLayout(tileCount: model.tiles.count)

        // Measured against the display itself rather than against `visibleFrame`.
        //
        // `visibleFrame` means "whatever the Dock has left over", and for something that *replaces*
        // the Dock that is precisely the wrong reference. Worse, it is a moving target read at the
        // worst possible moment: this runs as the app parks the real Dock on another edge, catches
        // the display mid-transition, and AppKit goes on handing back that same answer because
        // nothing posts a second screen-parameter change once the Dock settles. The bar came up
        // 1632 points wide, 48 points off the bottom of an 1800-point screen, and stayed there.
        //
        // The display's own frame does not move. The menu bar is the one inset that still matters,
        // and taking it as the gap at the top of `visibleFrame` is safe even when the rest of that
        // rectangle is stale: no Dock, wherever it is parked, changes where the menu bar ends.
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        // The narrowest display, not this one. Every strip shares one style — they are the same
        // dock — so the icons have to be a size that fits on all of them; sized per screen, the two
        // would take turns overwriting each other's answer on every tick.
        let narrowest = NSScreen.screens.map(\.frame.width).min() ?? screen.frame.width
        let along = narrowest - requested.edgeMargin * 2
        // The strip's icons do not get the whole edge: they share it with segments that cannot
        // shrink — our own button, the application in front, playback and the clock. Handing them
        // the full width lets a crowded dock push the clock off the screen, which is exactly what
        // showing every pinned application rather than only the running ones would have done.
        let available = max(200, along - Self.roomTheBarNeedsBesidesIcons(playing: model.nowPlaying != nil))

        // One moment, one screen, one answer: the icons the view draws and the window they have to
        // fit inside are decided here together. Worked out in two places, they disagreed and the
        // dock ran off the edge.
        let style = layout.clamped(requested, toLength: available)
        if model.style != style { model.style = style }

        var size = CGSize(width: 400, height: style.barHeight)
        // A taskbar spans its edge; a dock hugs its icons. That is the difference, and it is the
        // window's size rather than anything the view can decide for itself.
        if style.fillsEdge {
            size.width = screen.frame.width
        }
        if model.windowSize != size { model.windowSize = size }

        let x = style.fillsEdge ? screen.frame.minX : screen.frame.midX - size.width / 2
        // Parked, the strip slides off its own edge and leaves a sliver behind. The window stays
        // whole and stays hovered — which is what lets a hover on the sliver bring it back without
        // anything watching the mouse.
        let parked = style.autoHides && model.isAutoHidden
        let hiddenBy = parked ? size.height - DockStyle.revealStrip : 0
        let origin: CGPoint = switch style.edge {
        case .bottom:
            CGPoint(x: x, y: screen.frame.minY + style.edgeMargin - hiddenBy)
        case .top:
            // Under the menu bar, not over it.
            CGPoint(x: x, y: screen.frame.maxY - menuBar - size.height - style.edgeMargin + hiddenBy)
        }

        let frame = CGRect(origin: origin, size: size)
        reserveSpace(for: style, frame: frame, on: screen)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: false)
    }

    /// Tells window placement to keep out of the strip the dock is on.
    ///
    /// Nothing can make another app's windows respect it — only the Dock and the menu bar shrink
    /// `visibleFrame` — but every tiling command, snap and saved layout in this app reads one
    /// property, and this is what that property subtracts. So the promise is the honest one: windows
    /// *this app* places leave the dock alone.
    private func reserveSpace(for style: DockStyle, frame: CGRect, on screen: NSScreen) {
        // A strip that parks itself holds nothing back, the same as an auto-hiding system Dock.
        guard style.reservesSpace, style.fillsEdge, !style.autoHides else {
            DockReservation.shared.set(.init(), forScreenNumber: screen.deviceNumber)
            return
        }

        var insets = DockReservation.Insets()
        switch style.edge {
        case .bottom: insets.bottom = frame.height + style.edgeMargin
        case .top: insets.top = frame.height + style.edgeMargin
        }
        DockReservation.shared.set(insets, forScreenNumber: screen.deviceNumber)
    }

    // MARK: - Interaction

    @ObservationIgnored private let folderStack = FolderStackPanel()

    private func open(_ tile: DockTile, anchoredAt frame: CGRect = .zero) {
        switch tile.kind {
        case .folder:
            // A folder in a dock is a shortcut to what is *in* it. Opening the Finder was what
            // happened when the dock had nowhere to put the answer; now it has.
            guard let url = tile.url, let panel = panelUnderPointer else { return }
            folderStack.toggle(
                folder: url,
                anchor: screenRect(of: frame, in: panel),
                style: model.style
            )
            return
        case .application:
            if let identifier = tile.bundleIdentifier,
               let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: identifier).first {
                running.activate(options: [.activateAllWindows])
                return
            }
            guard let url = tile.url else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .file, .trash:
            guard let url = tile.url else { return }
            NSWorkspace.shared.open(url)
        case .separator:
            break
        }
    }

    /// What a dock does with files dropped on it.
    ///
    /// Three answers, and no fourth: an application opens them, the bin takes them, a folder
    /// receives them. Anything else refuses, and refusing is the point — a drop that reports success
    /// and does nothing is a file somebody believes they have filed.
    ///
    /// Nothing is deleted here. The bin means the bin: the files are moved there and can be put
    /// back, which is the difference between the Dock's bin and `rm`.
    func accept(_ urls: [URL], on tile: DockTile) -> Bool {
        guard !urls.isEmpty else { return false }

        // An application dropped on the dock is being *put* there, not opened with something. That
        // is what the Dock does, and it means dragging an icon along the bar to reorder it and
        // dragging an app in from the Finder to pin it are the same gesture arriving at the same
        // place — no need to track whether a drag started inside the bar or outside it, which is a
        // piece of state that goes stale the moment a drag is cancelled.
        if urls.allSatisfy({ $0.pathExtension == "app" }) {
            return pin(urls, at: tile)
        }

        switch tile.kind {
        case .application:
            guard let application = tile.url else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration)
            return true

        case .trash:
            var moved = false
            for url in urls {
                // Each on its own: one file that will not move must not take the rest with it.
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    moved = true
                } catch {
                    logger.error("could not move \(url.lastPathComponent, privacy: .public) to the bin: \(error.localizedDescription, privacy: .public)")
                }
            }
            return moved

        case .folder:
            guard let folder = tile.url else { return false }
            var moved = false
            for url in urls {
                let destination = folder.appendingPathComponent(url.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    logger.notice("something is already called \(url.lastPathComponent, privacy: .public) there")
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: url, to: destination)
                    moved = true
                } catch {
                    logger.error("could not move into the folder: \(error.localizedDescription, privacy: .public)")
                }
            }
            return moved

        case .file, .separator:
            return false
        }
    }

    /// Puts applications in the dock at the position they were dropped on.
    ///
    /// Moving and adding are one operation: something already pinned is taken out of the list before
    /// being put back at the new place, so dragging an icon three to the left does not leave a copy
    /// of it behind.
    private func pin(_ applications: [URL], at tile: DockTile) -> Bool {
        let identifiers = applications.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !identifiers.isEmpty else { return false }
        // Dropping something on itself is a drag that changed nothing.
        guard identifiers != [tile.bundleIdentifier].compactMap({ $0 }) else { return false }

        preferences.dockPins = Self.reordered(
            preferences.dockPins, moving: identifiers, toward: tile.bundleIdentifier
        )
        reloadTiles()
        return true
    }

    /// The new order.
    ///
    /// Plain arithmetic on strings so it can be tested: the off-by-one in "insert where the thing I
    /// removed used to be" is the whole of this function's difficulty.
    nonisolated static func reordered(
        _ pins: [String],
        moving identifiers: [String],
        toward anchor: String?
    ) -> [String] {
        var result = pins
        result.removeAll { identifiers.contains($0) }

        // The anchor is looked up *after* the removal, or an icon moved rightwards lands one place
        // short of where it was dropped.
        let index = anchor.flatMap { result.firstIndex(of: $0) } ?? result.count
        result.insert(contentsOf: identifiers, at: index)
        return result
    }

    private func quit(_ tile: DockTile) {
        guard let identifier = tile.bundleIdentifier else { return }
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
            application.terminate()
        }
    }

    private func updateWindowTimer() {
        windowTimer?.invalidate()
        windowTimer = nil
        // Runs for every layout now: the badges are read here, and they belong on all of them.
        windowTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Order matters: the window list is read once, then everything reads it.
                self?.refreshWindows()
                self?.refreshBar()
                self?.enforceReservation()
                self?.updateFullScreenVisibility()
                self?.scheduleLayout()
            }
        }
    }

    // MARK: - Keeping up

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        // Deliberately not `didActivateApplication`: it fires on every switch between windows and
        // tells us nothing a dock shows. Launching and quitting are what change the dots.
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadTiles() }
            })
        }

        // Switching applications is one way something goes full screen, and swiping between Spaces
        // is the other. Swiping is not an application switch, which is why it was missed: the bar
        // sat there until the next tick and then came back a second and a half after the swipe had
        // finished. Both are asked the same question.
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateFullScreenVisibility() }
                }
            )
        }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // A display arriving or leaving is a strip arriving or leaving, not just a
                // re-measurement — `ensurePanel` adds and removes them and then lays them all out.
                MainActor.assumeIsolated { self?.ensurePanel() }
            }
        )

        // The Dock says so when its own settings change, which is how a rearranged Dock shows up
        // here without polling for it.
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.dock.prefchanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadTiles() }
        }
    }
}
