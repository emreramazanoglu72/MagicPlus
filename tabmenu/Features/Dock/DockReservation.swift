//
//  DockReservation.swift
//  MagicPlus
//

import AppKit
import Foundation

/// Screen space the app's own dock has taken, so window placement stops using it.
///
/// Only the Dock and the menu bar can shrink `NSScreen.visibleFrame`; nothing a third party does
/// will make another app's windows respect a strip down the side of the screen. What *can* be done
/// is to stop putting windows there ourselves — and since every tiling command, every snap and
/// every saved layout in this app derives its target from one property, subtracting the strip there
/// covers all of them at once.
///
/// So the claim this supports is the honest one: windows this app places leave the dock alone. A
/// window somebody drags over it by hand is theirs to drag.
///
/// Held outside the main actor because `NSScreen.accessibilityVisibleFrame` is read from wherever
/// window management happens, and a lock around two numbers is cheaper than making that call
/// asynchronous.
nonisolated final class DockReservation: @unchecked Sendable {
    static let shared = DockReservation()

    struct Insets: Equatable, Sendable {
        var left: CGFloat = 0
        var right: CGFloat = 0
        var bottom: CGFloat = 0
        var top: CGFloat = 0

        var isEmpty: Bool { self == Insets() }
    }

    private let lock = NSLock()
    /// Keyed by the screen's device number, so a dock on the second display reserves space on that
    /// display and not on the one being tiled.
    private var byScreen: [Int: Insets] = [:]

    func set(_ insets: Insets, forScreenNumber number: Int) {
        lock.withLock {
            if insets.isEmpty {
                byScreen.removeValue(forKey: number)
            } else {
                byScreen[number] = insets
            }
        }
    }

    func clearAll() {
        lock.withLock { byScreen.removeAll() }
    }

    func insets(forScreenNumber number: Int) -> Insets {
        lock.withLock { byScreen[number] ?? Insets() }
    }

    /// Applies the reservation to an area in Cocoa coordinates.
    func applying(to frame: CGRect, screenNumber: Int) -> CGRect {
        let insets = insets(forScreenNumber: screenNumber)
        guard !insets.isEmpty else { return frame }

        var result = frame
        result.origin.x += insets.left
        result.size.width -= insets.left + insets.right
        result.origin.y += insets.bottom
        result.size.height -= insets.bottom + insets.top
        // Never hand back something inverted, whatever the numbers say.
        result.size.width = max(120, result.size.width)
        result.size.height = max(120, result.size.height)
        return result
    }
}

extension NSScreen {
    /// The number macOS knows this display by, which is what a reservation is filed under.
    var deviceNumber: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }
}
