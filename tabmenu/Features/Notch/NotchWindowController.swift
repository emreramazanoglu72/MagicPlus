//
//  NotchWindowController.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// Hosts the island above the menu bar and tracks the pointer over the notch.
///
/// The window itself is always the full expanded size and fully transparent; the island
/// inside it grows and shrinks. Sizing the window instead would fight SwiftUI's animation
/// and make the shape jump between states.
@MainActor
final class NotchWindowController {
    private let model: NotchModel
    private let preferences: Preferences
    private let monitor = NotchHoverMonitor()

    private var window: NSPanel?
    private var leaveTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    private static let windowWidth: CGFloat = 560
    private static let windowHeight: CGFloat = 440
    /// Grace period so the pointer can travel from the notch down onto the panel.
    private static let leaveDelay: Duration = .milliseconds(220)
    private static let hitPadding: CGFloat = 6

    init(
        shelf: ShelfStore,
        calendar: CalendarService,
        mixer: AudioMixerService,
        brightness: DisplayBrightnessService,
        preferences: Preferences
    ) {
        self.model = NotchModel(
            shelf: shelf, calendar: calendar, mixer: mixer,
            brightness: brightness, preferences: preferences
        )
        self.preferences = preferences

        monitor.onMove = { [weak self] location, isDragging in
            self?.handle(location: location, isDragging: isDragging)
        }
        monitor.onClick = { [weak self] location in
            self?.handleClick(at: location)
        }

        // Displays come and go; the window must follow the notch or the island ends up
        // mid-screen and hover hit-testing keeps using the stale frame.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionWindow() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    // MARK: - Lifecycle

    func updateMonitoring() {
        if preferences.isNotchPanelEnabled {
            ensureWindow()
            monitor.start()
            model.startUpdates()
        } else {
            monitor.stop()
            model.stopUpdates()
            leaveTask?.cancel()
            window?.orderOut(nil)
            window = nil
        }
    }

    func stop() {
        monitor.stop()
        model.stopUpdates()
        leaveTask?.cancel()
        window?.orderOut(nil)
        window = nil
    }

    /// Lets other features surface a transient activity in the island.
    func announce(_ activity: NotchActivity) {
        model.present(activity)
        model.refreshHardwareState()
    }

    func setActivitiesSuppressed(_ suppressed: Bool) {
        model.suppressesActivities = suppressed
    }

    // MARK: - Hover

    private func handle(location: CGPoint, isDragging: Bool) {
        guard let screen = NotchGeometry.primaryScreen, let window else { return }

        let anchor = NotchGeometry.anchorFrame(on: screen)
            .insetBy(dx: -Self.hitPadding, dy: -Self.hitPadding)
        let isOverAnchor = anchor.contains(location)
        let isOverPanel = model.isExpanded && window.frame.contains(location)

        if isOverAnchor || isOverPanel {
            leaveTask?.cancel()
            leaveTask = nil
            expand()
        } else if model.isExpanded, !isDragging {
            scheduleLeave()
        }
    }

    /// A click on the collapsed capsule either joins the meeting it shows or opens the
    /// panel on the matching tab.
    private func handleClick(at location: CGPoint) {
        guard model.stage == .activity,
              let screen = NotchGeometry.primaryScreen,
              activityCapsuleRect(on: screen).contains(location)
        else { return }

        let served = model.handleActivityClick()
        if !served { expand() }
    }

    /// Mirrors the island's activity-stage geometry (NotchIslandView): capsule width is the
    /// anchor plus the activity's side panels and insets, hanging from the top of the screen.
    private func activityCapsuleRect(on screen: NSScreen) -> CGRect {
        let anchor = NotchGeometry.anchorFrame(on: screen)
        let sideWidth = model.activity?.sideWidth ?? NotchIslandView.defaultSideWidth
        let width = anchor.width + sideWidth * 2 + NotchIslandView.contentInset * 2
        let height = anchor.height + NotchIslandView.verticalPadding
        return CGRect(
            x: anchor.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func expand() {
        // Only interactive while open, so the menu bar stays clickable the rest of the time.
        window?.ignoresMouseEvents = false
        window?.orderFrontRegardless()
        model.setHovering(true)
    }

    private func scheduleLeave() {
        guard leaveTask == nil else { return }
        leaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.leaveDelay)
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    private func collapse() {
        leaveTask = nil
        model.setHovering(false)
        window?.ignoresMouseEvents = true
    }

    // MARK: - Window

    private func ensureWindow() {
        guard window == nil, let screen = NotchGeometry.primaryScreen else {
            positionWindow()
            return
        }

        let anchor = NotchGeometry.anchorFrame(on: screen)
        let panel = FloatingPanel.makeNonActivating(
            size: CGSize(width: Self.windowWidth, height: Self.windowHeight),
            content: NotchIslandView(model: model, anchorSize: anchor.size)
        )
        // Above the menu bar, which the island grows out of.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        window = panel

        positionWindow()
        panel.orderFrontRegardless()
    }

    private func positionWindow() {
        guard let window, let screen = NotchGeometry.primaryScreen else { return }
        let anchor = NotchGeometry.anchorFrame(on: screen)
        let origin = CGPoint(
            x: anchor.midX - Self.windowWidth / 2,
            y: screen.frame.maxY - Self.windowHeight
        )
        window.setFrame(
            CGRect(origin: origin, size: CGSize(width: Self.windowWidth, height: Self.windowHeight)),
            display: false
        )
    }
}
