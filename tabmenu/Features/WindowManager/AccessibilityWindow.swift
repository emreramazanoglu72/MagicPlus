//
//  AccessibilityWindow.swift
//  tabmenu
//

import AppKit
import ApplicationServices

/// Thin wrapper around the focused `AXUIElement` of another application.
struct AccessibilityWindow {
    let element: AXUIElement
    let processIdentifier: pid_t
    let applicationName: String?
    let title: String?

    /// Identity used to remember per-window state across activations.
    var key: WindowKey {
        WindowKey(processIdentifier: processIdentifier, title: title ?? "")
    }

    // MARK: - Lookup

    /// - Parameter fallback: Used when tabmenu itself is frontmost, which happens while the
    ///   popover is open. Acting on our own window would never be what the user meant.
    static func focused(preferring fallback: NSRunningApplication? = nil) -> AccessibilityWindow? {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        var candidate = NSWorkspace.shared.frontmostApplication
        if candidate == nil || candidate?.processIdentifier == ownProcessIdentifier {
            candidate = fallback
        }

        guard let application = candidate,
              application.processIdentifier != ownProcessIdentifier
        else { return nil }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

        guard let window = copyElement(applicationElement, attribute: kAXFocusedWindowAttribute)
            ?? copyElement(applicationElement, attribute: kAXMainWindowAttribute)
        else { return nil }

        return AccessibilityWindow(
            element: window,
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName,
            title: copyValue(window, attribute: kAXTitleAttribute) as? String
        )
    }

    // MARK: - Geometry

    var frame: CGRect? {
        guard let positionValue = Self.copyValue(element, attribute: kAXPositionAttribute),
              let sizeValue = Self.copyValue(element, attribute: kAXSizeAttribute)
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              // swiftlint:disable:next force_cast
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    /// Applies position and size. The position is written twice because applications that
    /// clamp their own size can otherwise leave the window offset from the requested origin.
    ///
    /// Succeeding at either write counts: some windows accept a move but refuse a resize,
    /// and repositioning them is still the outcome the user asked for.
    @discardableResult
    func setFrame(_ frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size

        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }

        let positionStatus = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        let sizeStatus = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)

        return positionStatus == .success || sizeStatus == .success
    }

    // MARK: - Attribute helpers

    private static func copyValue(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return status == .success ? value : nil
    }

    private static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }
}

struct WindowKey: Hashable {
    let processIdentifier: pid_t
    let title: String
}

extension CGRect {
    /// Converts between Cocoa (bottom-left origin) and Accessibility (top-left origin) space.
    /// The transform is its own inverse, so one method covers both directions.
    func flippedBetweenScreenSpaces() -> CGRect {
        guard let primary = NSScreen.screens.first else { return self }
        return CGRect(
            x: minX,
            y: primary.frame.maxY - maxY,
            width: width,
            height: height
        )
    }
}

extension NSScreen {
    /// The screen containing a point expressed in Accessibility space.
    static func containing(accessibilityPoint point: CGPoint) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        return NSScreen.screens.first { $0.frame.contains(cocoaPoint) }
    }

    /// Usable area (menu bar and Dock excluded) in Accessibility space.
    var accessibilityVisibleFrame: CGRect {
        visibleFrame.flippedBetweenScreenSpaces()
    }
}
