//
//  NotchGeometry.swift
//  tabmenu
//

import AppKit

/// Locates the physical notch, or a stand-in area on displays without one.
enum NotchGeometry {
    /// Width of the virtual handle used on notchless displays.
    private static let virtualHandleWidth: CGFloat = 180

    /// The notch cut-out in Cocoa screen coordinates, or `nil` on displays without one.
    static func notchFrame(on screen: NSScreen) -> CGRect? {
        let inset = screen.safeAreaInsets.top
        guard inset > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              rightArea.minX > leftArea.maxX
        else { return nil }

        return CGRect(
            x: leftArea.maxX,
            y: screen.frame.maxY - inset,
            width: rightArea.minX - leftArea.maxX,
            height: inset
        )
    }

    /// Area the panel hangs from: the real notch when present, otherwise a centred handle
    /// occupying the menu bar strip.
    static func anchorFrame(on screen: NSScreen) -> CGRect {
        if let notchFrame = notchFrame(on: screen) { return notchFrame }

        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return CGRect(
            x: screen.frame.midX - virtualHandleWidth / 2,
            y: screen.frame.maxY - menuBarHeight,
            width: virtualHandleWidth,
            height: menuBarHeight
        )
    }

    /// Screen the notch panel lives on: the one holding the menu bar.
    static var primaryScreen: NSScreen? {
        NSScreen.screens.first
    }
}
