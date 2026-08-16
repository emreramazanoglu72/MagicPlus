//
//  DockItemLister.swift
//  tabmenu
//

import AppKit
import ApplicationServices

struct DockItem: Identifiable, Equatable {
    let id: String
    let title: String
    /// Icon bounds in Accessibility space (top-left origin).
    let frame: CGRect
    let bundleURL: URL?
    let processIdentifier: pid_t?

    var isRunning: Bool { processIdentifier != nil }
}

/// Reads the Dock's own Accessibility tree to locate application icons.
@MainActor
enum DockItemLister {
    private static let applicationDockItemSubrole = "AXApplicationDockItem"
    private static let messagingTimeout: Float = 0.2

    /// Bounds of the whole Dock, used to skip work while the pointer is elsewhere.
    static func dockFrame() -> CGRect? {
        guard let list = dockItemList() else { return nil }
        return frame(of: list)
    }

    static func applicationItems() -> [DockItem] {
        guard let list = dockItemList() else { return [] }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return [] }

        let runningApplications = NSWorkspace.shared.runningApplications

        return children.enumerated().compactMap { index, child in
            guard string(child, attribute: kAXSubroleAttribute) == applicationDockItemSubrole,
                  let itemFrame = frame(of: child)
            else { return nil }

            let title = string(child, attribute: kAXTitleAttribute) ?? "Unknown"
            let bundleURL = copy(child, attribute: kAXURLAttribute) as? URL
            let application = runningApplications.first { candidate in
                if let bundleURL, let candidateURL = candidate.bundleURL {
                    return candidateURL.standardizedFileURL == bundleURL.standardizedFileURL
                }
                return candidate.localizedName == title
            }

            return DockItem(
                id: "\(index)-\(title)",
                title: title,
                frame: itemFrame,
                bundleURL: bundleURL,
                processIdentifier: application?.processIdentifier
            )
        }
    }

    // MARK: - Dock element

    private static func dockItemList() -> AXUIElement? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first
        else { return nil }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, messagingTimeout)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return nil }

        return children.first { string($0, attribute: kAXRoleAttribute) == kAXListRole as String }
    }

    // MARK: - Attribute helpers

    private static func frame(of element: AXUIElement) -> CGRect? {
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

    private static func copy(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        copy(element, attribute: attribute) as? String
    }
}

extension CGPoint {
    /// Converts a Cocoa mouse location into Accessibility space.
    var inAccessibilitySpace: CGPoint {
        guard let primary = NSScreen.screens.first else { return self }
        return CGPoint(x: x, y: primary.frame.maxY - y)
    }
}
