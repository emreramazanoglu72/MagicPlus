//
//  MenuTreeReader.swift
//  tabmenu
//

import AppKit
import ApplicationServices

/// One executable menu item of the frontmost application.
struct MenuCommand: Identifiable, Equatable {
    let id: String
    let title: String
    /// Where it lives, e.g. "File › Export".
    let path: String
    let element: AXUIElement
    let isEnabled: Bool

    static func == (lhs: MenuCommand, rhs: MenuCommand) -> Bool { lhs.id == rhs.id }
}

/// Walks another application's menu bar over the Accessibility API, flattening it into a
/// searchable command list.
@MainActor
enum MenuTreeReader {
    private static let messagingTimeout: Float = 0.3
    private static let maximumDepth = 4
    private static let maximumCommands = 1500

    static func commands(forProcessIdentifier processIdentifier: pid_t) -> [MenuCommand] {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        guard let menuBar = element(application, attribute: kAXMenuBarAttribute),
              let topLevel = children(of: menuBar)
        else { return [] }

        var commands: [MenuCommand] = []
        // The first menu is the Apple menu — system-wide, not this app's commands.
        for menu in topLevel.dropFirst() {
            guard commands.count < maximumCommands else { break }
            let menuTitle = title(of: menu) ?? ""
            collect(from: menu, path: [menuTitle], into: &commands)
        }
        return commands
    }

    static func execute(_ command: MenuCommand) {
        AXUIElementPerformAction(command.element, kAXPressAction as CFString)
    }

    // MARK: - Traversal

    private static func collect(from element: AXUIElement, path: [String], into commands: inout [MenuCommand]) {
        guard path.count <= maximumDepth, commands.count < maximumCommands else { return }
        guard let submenuChildren = children(of: element) else { return }

        for child in submenuChildren {
            // AXMenuBarItem/AXMenuItem wrap their contents in an AXMenu with no title.
            if role(of: child) == kAXMenuRole as String {
                collect(from: child, path: path, into: &commands)
                continue
            }

            guard let itemTitle = title(of: child), !itemTitle.isEmpty else { continue }

            if let submenu = children(of: child), !submenu.isEmpty {
                collect(from: child, path: path + [itemTitle], into: &commands)
            } else {
                commands.append(
                    MenuCommand(
                        id: (path + [itemTitle]).joined(separator: "|"),
                        title: itemTitle,
                        path: path.joined(separator: " › "),
                        element: child,
                        isEnabled: isEnabled(child)
                    )
                )
            }
            if commands.count >= maximumCommands { return }
        }
    }

    // MARK: - Scoring

    /// Relevance of a command for a query; `nil` means no match. Pure, for testing.
    nonisolated static func score(query: String, title: String, path: String) -> Int? {
        let query = query.lowercased()
        let lowerTitle = title.lowercased()
        guard !query.isEmpty else { return 0 }

        if lowerTitle.hasPrefix(query) { return 100 }
        if lowerTitle.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 80 }
        if lowerTitle.contains(query) { return 60 }
        if path.lowercased().contains(query) { return 30 }
        return nil
    }

    // MARK: - Attribute helpers

    private static func copy(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = copy(parent, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        copy(element, attribute: kAXChildrenAttribute) as? [AXUIElement]
    }

    private static func title(of element: AXUIElement) -> String? {
        (copy(element, attribute: kAXTitleAttribute) as? String)?
            .trimmingCharacters(in: .whitespaces)
    }

    private static func role(of element: AXUIElement) -> String? {
        copy(element, attribute: kAXRoleAttribute) as? String
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        (copy(element, attribute: kAXEnabledAttribute) as? Bool) ?? true
    }
}
