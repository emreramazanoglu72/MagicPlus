//
//  WindowManagerService.swift
//  tabmenu
//

import AppKit
import Observation
import os

/// Moves the focused window into zones, cycling through variants when the same command
/// is repeated and remembering the original frame so it can be restored.
@Observable
@MainActor
final class WindowManagerService {
    enum Failure: LocalizedError, Equatable {
        case accessibilityDenied
        case noFocusedWindow
        case windowNotResizable(String)

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                String(localized: "Accessibility access is required to move windows.",
                       comment: "Shown when a window command runs without permission")
            case .noFocusedWindow:
                String(localized: "No focused window to move.",
                       comment: "Shown when no window could be targeted")
            case .windowNotResizable(let name):
                String(localized: "\(name) does not allow resizing.",
                       comment: "Shown when an app refuses to be resized; the placeholder is the app name")
            }
        }
    }

    private(set) var lastFailure: Failure?

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "WindowManager")
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let permission: AccessibilityPermission
    @ObservationIgnored private let frontmostTracker: FrontmostApplicationTracker
    @ObservationIgnored private var restoreFrames: [WindowKey: CGRect] = [:]

    private static let restoreCacheLimit = 64

    init(
        preferences: Preferences,
        frontmostTracker: FrontmostApplicationTracker,
        permission: AccessibilityPermission? = nil
    ) {
        self.preferences = preferences
        self.frontmostTracker = frontmostTracker
        self.permission = permission ?? .shared
    }

    // MARK: - Commands

    func perform(_ action: WindowAction) {
        logger.notice("perform \(action.rawValue, privacy: .public), trusted=\(self.permission.isTrusted)")

        guard permission.isTrusted else {
            lastFailure = .accessibilityDenied
            permission.request()
            return
        }
        guard let window = AccessibilityWindow.focused(preferring: frontmostTracker.lastExternalApplication) else {
            logger.error("no target window (fallback=\(self.frontmostTracker.lastExternalApplication?.localizedName ?? "nil", privacy: .public))")
            lastFailure = .noFocusedWindow
            return
        }

        lastFailure = nil
        logger.notice("""
            target=\(window.applicationName ?? "?", privacy: .public) \
            title=\(window.title ?? "?", privacy: .private) \
            frame=\(String(describing: window.frame), privacy: .public)
            """)

        if action == .restore {
            restore(window)
            return
        }
        guard let zone = nextZone(for: action, window: window) else { return }
        move(window, to: zone)
    }

    /// Applies a zone directly, bypassing the cycle used by keyboard shortcuts.
    func apply(_ zone: WindowZone) {
        guard permission.isTrusted else {
            lastFailure = .accessibilityDenied
            permission.request()
            return
        }
        guard let window = AccessibilityWindow.focused(preferring: frontmostTracker.lastExternalApplication) else {
            lastFailure = .noFocusedWindow
            return
        }
        lastFailure = nil
        move(window, to: zone)
    }

    /// Places a specific window, used by drag-to-edge snapping where the target is already known.
    /// Pass the screen the drop happened on so the window lands where the preview showed it.
    func snap(_ window: AccessibilityWindow, to zone: WindowZone, on screen: NSScreen? = nil) {
        lastFailure = nil
        move(window, to: zone, on: screen)
    }

    /// Frame a zone would occupy, for drawing the drag preview.
    func previewFrame(for zone: WindowZone, on screen: NSScreen) -> CGRect {
        frame(for: zone, in: screen.accessibilityVisibleFrame)
    }

    // MARK: - Placement

    private func move(_ window: AccessibilityWindow, to zone: WindowZone, on screen: NSScreen? = nil) {
        guard let area = screen?.accessibilityVisibleFrame ?? visibleArea(for: window) else {
            logger.error("could not resolve a screen for the target window")
            lastFailure = .noFocusedWindow
            return
        }

        let target = frame(for: zone, in: area)
        rememberRestoreFrame(for: window)
        let didApply = window.setFrame(target)

        logger.notice("""
            zone=\(zone.rawValue, privacy: .public) area=\(String(describing: area), privacy: .public) \
            target=\(String(describing: target), privacy: .public) applied=\(didApply) \
            result=\(String(describing: window.frame), privacy: .public)
            """)

        if !didApply {
            lastFailure = .windowNotResizable(window.applicationName ?? "This window")
        }
    }

    private func restore(_ window: AccessibilityWindow) {
        guard let frame = restoreFrames.removeValue(forKey: window.key) else { return }
        window.setFrame(frame)
    }

    private func nextZone(for action: WindowAction, window: AccessibilityWindow) -> WindowZone? {
        let zones = action.cycle
        guard let first = zones.first else { return nil }
        guard zones.count > 1,
              let area = visibleArea(for: window),
              let current = window.frame
        else { return first }

        let matchedIndex = zones.firstIndex {
            current.isApproximatelyEqual(to: frame(for: $0, in: area))
        }
        guard let matchedIndex else { return first }
        return zones[(matchedIndex + 1) % zones.count]
    }

    private func frame(for zone: WindowZone, in area: CGRect) -> CGRect {
        let inset = preferences.windowGap / 2
        let workArea = area.insetBy(dx: inset, dy: inset)
        return zone.frame(in: workArea).insetBy(dx: inset, dy: inset).integral
    }

    private func visibleArea(for window: AccessibilityWindow) -> CGRect? {
        let screen = window.frame
            .flatMap { NSScreen.containing(accessibilityPoint: CGPoint(x: $0.midX, y: $0.midY)) }
            ?? NSScreen.main
        return screen?.accessibilityVisibleFrame
    }

    private func rememberRestoreFrame(for window: AccessibilityWindow) {
        guard restoreFrames[window.key] == nil, let frame = window.frame else { return }
        if restoreFrames.count >= Self.restoreCacheLimit {
            restoreFrames.removeAll()
        }
        restoreFrames[window.key] = frame
    }
}
