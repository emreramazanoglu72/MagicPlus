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

    private static let windowWidth: CGFloat = 640
    private static let windowHeight: CGFloat = 440
    /// Grace period so the pointer can travel from the notch down onto the panel.
    private static let leaveDelay: Duration = .milliseconds(220)
    private static let hitPadding: CGFloat = 6

    init(
        shelf: ShelfStore,
        downloads: DownloadStore,
        calendar: CalendarService,
        mixer: AudioMixerService,
        brightness: DisplayBrightnessService,
        preferences: Preferences
    ) {
        self.model = NotchModel(
            shelf: shelf, downloads: downloads, calendar: calendar, mixer: mixer,
            brightness: brightness, preferences: preferences
        )
        self.preferences = preferences

        monitor.onMove = { [weak self] location, isDragging in
            self?.handle(location: location, isDragging: isDragging)
        }
        monitor.onClick = { [weak self] location in
            self?.handleClick(at: location)
        }
        model.onStageChange = { [weak self] stage in
            self?.applyInteractivity(for: stage)
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

    /// Passes on which tab a browser is making sound with.
    func setBrowserPlayback(_ playback: BrowserPlayback?) {
        model.setBrowserPlayback(playback)
    }

    /// Grows the island into a card asking about a link it found.
    func presentOffer(_ offer: DownloadOffer) {
        model.presentOffer(offer)
    }

    /// The window is inert while the island is only reporting, and takes the pointer the moment
    /// there is something on it to press.
    private func applyInteractivity(for stage: NotchModel.Stage) {
        if stage == .expanded || stage == .offer {
            window?.orderFrontRegardless()
            updatePointerCapture(at: NSEvent.mouseLocation)
        } else {
            window?.ignoresMouseEvents = true
        }
    }

    /// Takes the pointer only where the island actually is.
    ///
    /// The window is the full expanded size and almost entirely transparent, so leaving it
    /// interactive swallows clicks across a wide strip of the menu bar that has nothing drawn on
    /// it — and, worse, counts the pointer as being on the island when it is nowhere near it,
    /// which is what stopped a card from ever timing out.
    private func updatePointerCapture(at location: CGPoint) {
        guard let window, let screen = NotchGeometry.primaryScreen else { return }
        let isInteractive = model.isExpanded || model.isOffering
        window.ignoresMouseEvents = !(isInteractive && islandRect(on: screen).contains(location))
    }

    /// Where the island is drawn right now, in screen coordinates.
    private func islandRect(on screen: NSScreen) -> CGRect {
        let anchor = NotchGeometry.anchorFrame(on: screen)
        let strip = anchor.height + NotchIslandView.verticalPadding

        let size: CGSize
        switch model.stage {
        case .offer:
            // A capsule until it is pointed at, and the pointer has to be able to find it there.
            size = model.isOfferExpanded
                ? CGSize(
                    width: NotchIslandView.offerWidthValue,
                    height: strip + DownloadOfferCard.contentHeight
                )
                : CGSize(
                    width: anchor.width + NotchIslandView.offerCapsuleSideWidthValue * 2
                        + NotchIslandView.contentInset * 2,
                    height: strip
                )
        case .expanded:
            size = CGSize(
                width: NotchIslandView.expandedWidthValue,
                height: strip + NotchIslandView.panelContentHeight
            )
        case .activity:
            let sideWidth = model.activity?.sideWidth ?? NotchIslandView.defaultSideWidth
            size = CGSize(
                width: anchor.width + sideWidth * 2 + NotchIslandView.contentInset * 2,
                height: strip
            )
        case .idle:
            size = anchor.size
        }

        return CGRect(
            x: anchor.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Lets other features surface a transient activity in the island.
    func announce(_ activity: NotchActivity) {
        model.present(activity)
        model.refreshHardwareState()
    }

    /// Wiring for the download queue, which lives outside the island but reports into it.
    var island: NotchModel { model }

    func setActivitiesSuppressed(_ suppressed: Bool) {
        model.suppressesActivities = suppressed
    }

    // MARK: - Hover

    private func handle(location: CGPoint, isDragging: Bool) {
        guard let screen = NotchGeometry.primaryScreen, window != nil else { return }

        let anchor = NotchGeometry.anchorFrame(on: screen)
            .insetBy(dx: -Self.hitPadding, dy: -Self.hitPadding)
        let isOverAnchor = anchor.contains(location)
        // Measured against what is drawn, not against the window: the window is mostly empty
        // space, and treating a pointer in it as a pointer on the island is what kept a card
        // alive indefinitely and swallowed clicks meant for the menu bar.
        let isOverIsland = (model.isExpanded || model.isOffering)
            && islandRect(on: screen).contains(location)
        updatePointerCapture(at: location)

        if isOverAnchor || isOverIsland {
            leaveTask?.cancel()
            leaveTask = nil
            expand()
        } else if model.isExpanded, !isDragging {
            scheduleLeave()
        } else if model.isOffering {
            // A card is not held open by the pointer; leaving it simply restarts its clock.
            model.setHovering(false)
        }
    }

    /// A click on the collapsed capsule either joins the meeting it shows or opens the
    /// panel on the matching tab.
    private func handleClick(at location: CGPoint) {
        guard let screen = NotchGeometry.primaryScreen else { return }

        // The capsule an offer arrives as: aiming and clicking in one motion opens the prompt
        // rather than requiring the card to unfold first.
        if model.isOffering, !model.isOfferExpanded, islandRect(on: screen).contains(location) {
            model.acceptOffer()
            return
        }

        guard model.stage == .activity,
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
        updatePointerCapture(at: NSEvent.mouseLocation)
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
