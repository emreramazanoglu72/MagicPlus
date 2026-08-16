//
//  WindowLister.swift
//  tabmenu
//

import AppKit
import ApplicationServices

struct SwitchableWindow: Identifiable, Hashable {
    let id: String
    let element: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let applicationIcon: NSImage?
    let title: String
    let isMinimized: Bool
    /// CoreGraphics identifier, resolved by matching frames. Needed for thumbnails.
    let windowID: CGWindowID?
    /// Current bounds in Accessibility space.
    let frame: CGRect?

    var searchText: String { "\(applicationName) \(title)" }

    static func == (lhs: SwitchableWindow, rhs: SwitchableWindow) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Enumerates standard windows and performs window-level actions on them.
///
/// Titles come from the Accessibility API rather than `CGWindowListCopyWindowInfo`, because
/// window names in the CoreGraphics list require Screen Recording permission while
/// Accessibility is already needed for the rest of the app.
@MainActor
enum WindowLister {
    /// Applications that stop responding would otherwise block the whole listing.
    private static let messagingTimeout: Float = 0.25

    // MARK: - Listing

    static func switchableWindows() -> [SwitchableWindow] {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let onScreen = onScreenWindows()
        let order = frontToBackApplicationOrder(from: onScreen)

        let collected = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownProcessIdentifier }
            .flatMap { Self.windows(of: $0, matching: onScreen) }

        // Sorting keeps each application's own front-to-back window order intact.
        return collected.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = order[lhs.element.processIdentifier] ?? Int.max
                let rhsRank = order[rhs.element.processIdentifier] ?? Int.max
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }
            .map(\.element)
    }

    /// Windows of a single application, used by the Dock previews.
    static func windows(ofProcessIdentifier processIdentifier: pid_t) -> [SwitchableWindow] {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return [] }
        return windows(of: application, matching: onScreenWindows())
    }

    // MARK: - Actions

    static func focus(_ window: SwitchableWindow) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(
                window.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.processIdentifier)?.activate()
    }

    @discardableResult
    static func close(_ window: SwitchableWindow) -> Bool {
        guard let button = element(window.element, attribute: kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    @discardableResult
    static func minimize(_ window: SwitchableWindow) -> Bool {
        AXUIElementSetAttributeValue(
            window.element,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    static func quitApplication(of window: SwitchableWindow) {
        NSRunningApplication(processIdentifier: window.processIdentifier)?.terminate()
    }

    @discardableResult
    static func setFrame(_ frame: CGRect, for window: SwitchableWindow) -> Bool {
        AccessibilityWindow(
            element: window.element,
            processIdentifier: window.processIdentifier,
            applicationName: window.applicationName,
            title: window.title
        ).setFrame(frame)
    }

    // MARK: - CoreGraphics window list

    private struct CoreGraphicsWindow {
        let id: CGWindowID
        let processIdentifier: pid_t
        let bounds: CGRect
    }

    /// On-screen windows in z-order. Only identifiers, owners and bounds are read, none of
    /// which require Screen Recording permission.
    private static func onScreenWindows() -> [CoreGraphicsWindow] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return entries.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let identifier = entry[kCGWindowNumber as String] as? CGWindowID,
                  let processIdentifier = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }

            return CoreGraphicsWindow(id: identifier, processIdentifier: processIdentifier, bounds: bounds)
        }
    }

    private static func frontToBackApplicationOrder(
        from windows: [CoreGraphicsWindow]
    ) -> [pid_t: Int] {
        var order: [pid_t: Int] = [:]
        for window in windows where order[window.processIdentifier] == nil {
            order[window.processIdentifier] = order.count
        }
        return order
    }

    // MARK: - Accessibility

    private static func windows(
        of application: NSRunningApplication,
        matching onScreen: [CoreGraphicsWindow]
    ) -> [SwitchableWindow] {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeout)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success, let elements = value as? [AXUIElement] else { return [] }

        let applicationName = application.localizedName ?? "Unknown"
        let candidates = onScreen.filter { $0.processIdentifier == application.processIdentifier }

        return elements.enumerated().compactMap { index, element in
            guard isStandardWindow(element) else { return nil }
            let title = string(element, attribute: kAXTitleAttribute)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let windowFrame = frame(of: element)

            return SwitchableWindow(
                id: "\(application.processIdentifier)-\(index)",
                element: element,
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                applicationName: applicationName,
                applicationIcon: application.icon,
                title: title?.isEmpty == false ? title! : applicationName,
                isMinimized: bool(element, attribute: kAXMinimizedAttribute),
                windowID: identifier(for: windowFrame, among: candidates),
                frame: windowFrame
            )
        }
    }

    /// Frames from both APIs share the same top-left origin space, so matching on geometry
    /// is reliable and avoids the private `_AXUIElementGetWindow`.
    private static func identifier(
        for frame: CGRect?,
        among candidates: [CoreGraphicsWindow]
    ) -> CGWindowID? {
        guard let frame else { return nil }
        return candidates.first { $0.bounds.isApproximatelyEqual(to: frame, tolerance: 4) }?.id
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copy(element, attribute: kAXPositionAttribute),
              let sizeValue = copy(element, attribute: kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
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

    /// Panels, sheets and utility windows are skipped; only real document windows switch.
    private static func isStandardWindow(_ element: AXUIElement) -> Bool {
        if let subrole = string(element, attribute: kAXSubroleAttribute) {
            return subrole == kAXStandardWindowSubrole as String
        }
        return string(element, attribute: kAXRoleAttribute) == kAXWindowRole as String
    }

    // MARK: - Attribute helpers

    private static func copy(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        copy(element, attribute: attribute) as? String
    }

    private static func bool(_ element: AXUIElement, attribute: String) -> Bool {
        (copy(element, attribute: attribute) as? Bool) ?? false
    }
}
