//
//  WindowRescuer.swift
//  tabmenu
//

import AppKit
import os

/// Brings back windows stranded outside every screen — the classic aftermath of unplugging
/// an external display.
@MainActor
enum WindowRescuer {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "Rescue")

    /// Minimum grabbable strip: a window showing at least this much of itself is reachable
    /// by mouse and does not need rescuing.
    nonisolated static let grabbableWidth: CGFloat = 60
    nonisolated static let grabbableHeight: CGFloat = 40

    /// Moves every stranded window onto the main screen. Returns how many were moved.
    @discardableResult
    static func rescueOffscreenWindows() -> Int {
        let visibleAreas = NSScreen.screens.map(\.accessibilityVisibleFrame)
        guard let fallback = NSScreen.main?.accessibilityVisibleFrame ?? visibleAreas.first else { return 0 }

        var rescued = 0
        for window in WindowLister.switchableWindows() {
            guard !window.isMinimized,
                  let frame = window.frame,
                  let target = rescuedFrame(for: frame, visibleAreas: visibleAreas, fallback: fallback)
            else { continue }

            if WindowLister.setFrame(target, for: window) {
                rescued += 1
                logger.notice("rescued \(window.applicationName, privacy: .public) window")
            }
        }
        return rescued
    }

    /// Pure placement rule, separated for testing.
    ///
    /// Returns `nil` when the window already shows a grabbable area on some screen;
    /// otherwise a frame fitted inside `fallback`, shrunk only if it would not fit.
    nonisolated static func rescuedFrame(
        for frame: CGRect,
        visibleAreas: [CGRect],
        fallback: CGRect
    ) -> CGRect? {
        let isReachable = visibleAreas.contains { area in
            let overlap = area.intersection(frame)
            return overlap.width >= grabbableWidth && overlap.height >= grabbableHeight
        }
        guard !isReachable else { return nil }

        let width = min(frame.width, fallback.width)
        let height = min(frame.height, fallback.height)
        let x = min(max(frame.minX, fallback.minX), fallback.maxX - width)
        let y = min(max(frame.minY, fallback.minY), fallback.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
