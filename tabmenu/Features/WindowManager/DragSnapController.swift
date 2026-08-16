//
//  DragSnapController.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// Snaps a window when it is dragged against a screen edge, previewing the target zone first.
///
/// A drag only counts once the window has actually moved, so dragging text or a file to the
/// edge of the screen never triggers a snap.
@MainActor
final class DragSnapController {
    private let preferences: Preferences
    private let windowManager: WindowManagerService
    private let permission: AccessibilityPermission

    private var monitors: [Any] = []
    private var overlay: NSPanel?

    private var trackedWindow: AccessibilityWindow?
    private var dragOriginFrame: CGRect?
    private var hasWindowMoved = false
    private var candidate: (zone: WindowZone, screen: NSScreen)?
    private var lastEvaluation = Date.distantPast

    /// Distance from an edge that arms a snap.
    private static let edgeThreshold: CGFloat = 14
    /// Portion of an edge, measured from each end, that selects a quarter instead of a half.
    private static let cornerFraction: CGFloat = 0.25
    /// Accessibility queries are expensive; a drag does not need them every event.
    private static let evaluationInterval: TimeInterval = 0.05

    init(
        preferences: Preferences,
        windowManager: WindowManagerService,
        permission: AccessibilityPermission? = nil
    ) {
        self.preferences = preferences
        self.windowManager = windowManager
        self.permission = permission ?? .shared
    }

    // MARK: - Lifecycle

    func updateMonitoring() {
        let shouldRun = preferences.isDragSnapEnabled && permission.isTrusted
        shouldRun ? start() : stop()
    }

    private func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endDrag(applyingSnap: false)
    }

    // MARK: - Drag tracking

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged: continueDrag()
        case .leftMouseUp: endDrag(applyingSnap: true)
        default: break
        }
    }

    private func continueDrag() {
        guard Date().timeIntervalSince(lastEvaluation) >= Self.evaluationInterval else { return }
        lastEvaluation = Date()

        if trackedWindow == nil {
            trackedWindow = AccessibilityWindow.focused()
            dragOriginFrame = trackedWindow?.frame
            hasWindowMoved = false
        }

        guard let window = trackedWindow else { return }

        // Confirms the user is moving a window rather than dragging content out of one.
        if !hasWindowMoved, let origin = dragOriginFrame, let current = window.frame {
            hasWindowMoved = !current.origin.equalTo(origin.origin)
        }
        guard hasWindowMoved else { return }

        updateCandidate(for: NSEvent.mouseLocation)
    }

    private func endDrag(applyingSnap: Bool) {
        defer {
            trackedWindow = nil
            dragOriginFrame = nil
            hasWindowMoved = false
            candidate = nil
            hideOverlay()
        }

        guard applyingSnap,
              hasWindowMoved,
              let window = trackedWindow,
              let candidate
        else { return }

        windowManager.snap(window, to: candidate.zone, on: candidate.screen)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: - Zone resolution

    private func updateCandidate(for location: CGPoint) {
        guard let screen = screen(under: location),
              let zone = zone(for: location, on: screen)
        else {
            candidate = nil
            hideOverlay()
            return
        }

        if candidate?.zone != zone || candidate?.screen != screen {
            candidate = (zone, screen)
            showOverlay(for: zone, on: screen)
        }
    }

    /// `contains` excludes a rect's maximum edges, so a cursor pinned against the very top of
    /// a display misses every screen; fall back to the nearest one, never `NSScreen.main`.
    private func screen(under location: CGPoint) -> NSScreen? {
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(location) }) { return hit }
        return NSScreen.screens.min {
            distanceSquared(from: $0.frame, to: location) < distanceSquared(from: $1.frame, to: location)
        }
    }

    private func distanceSquared(from frame: CGRect, to point: CGPoint) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }

    /// Maps a pointer position near an edge onto a zone. Coordinates here are Cocoa's, so
    /// `maxY` is the top of the screen.
    private func zone(for location: CGPoint, on screen: NSScreen) -> WindowZone? {
        let frame = screen.frame
        let threshold = Self.edgeThreshold
        let cornerHeight = frame.height * Self.cornerFraction
        let cornerWidth = frame.width * Self.cornerFraction

        if location.x <= frame.minX + threshold {
            if location.y >= frame.maxY - cornerHeight { return .topLeftQuarter }
            if location.y <= frame.minY + cornerHeight { return .bottomLeftQuarter }
            return .leftHalf
        }

        if location.x >= frame.maxX - threshold {
            if location.y >= frame.maxY - cornerHeight { return .topRightQuarter }
            if location.y <= frame.minY + cornerHeight { return .bottomRightQuarter }
            return .rightHalf
        }

        if location.y >= frame.maxY - threshold {
            if location.x <= frame.minX + cornerWidth { return .leftHalf }
            if location.x >= frame.maxX - cornerWidth { return .rightHalf }
            return .maximize
        }

        if location.y <= frame.minY + threshold {
            return .bottomHalf
        }

        return nil
    }

    // MARK: - Overlay

    private func showOverlay(for zone: WindowZone, on screen: NSScreen) {
        let target = windowManager
            .previewFrame(for: zone, on: screen)
            .flippedBetweenScreenSpaces()

        let panel = overlay ?? makeOverlay()
        overlay = panel

        if panel.isVisible {
            panel.setFrame(target, display: true, animate: false)
        } else {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    private func hideOverlay() {
        guard let overlay, overlay.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            overlay.animator().alphaValue = 0
        } completionHandler: { [weak overlay] in
            overlay?.orderOut(nil)
        }
    }

    private func makeOverlay() -> NSPanel {
        let panel = FloatingPanel.makeNonActivating(size: CGSize(width: 200, height: 200), content: SnapOverlayView())
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .floating
        return panel
    }
}

private struct SnapOverlayView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Accent.windows.opacity(0.22))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Accent.windows.opacity(0.9), lineWidth: 2.5)
            }
            .accessibilityHidden(true)
    }
}
