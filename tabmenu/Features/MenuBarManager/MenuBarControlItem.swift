//
//  MenuBarControlItem.swift
//  tabmenu
//

import AppKit
import CoreGraphics

/// A status item the app owns purely to slice the menu bar into sections.
///
/// The bar lays its items out right to left, so a divider that grows wider than the space
/// left to it pushes everything on its left out of the bar entirely. That is the whole
/// hiding mechanism: no private API, nothing is moved or destroyed, and removing the
/// divider — or quitting — puts every item straight back where it was.
@MainActor
final class MenuBarControlItem: NSObject {
    enum Role {
        /// The chevron the user clicks; stays the same size whatever the state.
        case chevron
        /// The boundary that does the hiding by growing.
        case divider
    }

    let role: Role
    /// Receives the click, with the event so modifiers and the right button can be read.
    var onClick: ((NSEvent) -> Void)?

    private let statusItem: NSStatusItem
    private var isCollapsed: Bool

    /// Wide enough to push the items on its left past the start of the status area on any
    /// attached display, whatever the arrangement.
    private static var collapsedLength: CGFloat {
        (NSScreen.screens.map(\.frame.width).max() ?? 1_920) + 200
    }
    private static let dividerLength: CGFloat = 10

    init(role: Role, autosaveName: String, isCollapsed: Bool) {
        self.role = role
        self.isCollapsed = isCollapsed
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: role == .chevron ? NSStatusItem.variableLength : Self.dividerLength
        )
        super.init()

        statusItem.autosaveName = autosaveName
        configureButton()
        apply()
    }

    /// The item's left edge, which is the boundary every section test compares against.
    /// AppKit and the window server disagree about the origin of the *y* axis only, so this
    /// is directly comparable with what `MenuBarItemLister` reports.
    var minX: CGFloat? {
        guard let frame = statusItem.button?.window?.frame, frame.width > 0 else { return nil }
        return frame.minX
    }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        apply()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Pops a menu out of the item. It is detached again straight away so the next plain
    /// click still reaches the action rather than reopening the menu.
    func showMenu(_ menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Appearance

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func apply() {
        guard let button = statusItem.button else { return }

        switch role {
        case .chevron:
            button.image = NSImage(
                systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right",
                accessibilityDescription: isCollapsed
                    ? String(localized: "Show hidden menu bar items", comment: "Accessibility label")
                    : String(localized: "Hide menu bar items", comment: "Accessibility label")
            )
            button.toolTip = isCollapsed
                ? String(localized: "Show hidden menu bar items", comment: "Control item tooltip")
                : String(localized: "Hide menu bar items", comment: "Control item tooltip")

        case .divider:
            // Collapsed, the divider spans the bar; its glyph would then be drawn in the
            // middle of the screen, so it draws nothing at all while it is doing the hiding.
            statusItem.length = isCollapsed ? Self.collapsedLength : Self.dividerLength
            button.image = isCollapsed ? nil : Self.dividerImage
            button.toolTip = isCollapsed
                ? nil
                : String(
                    localized: "Items dragged to the left of this divider are hidden",
                    comment: "Divider tooltip"
                )
        }
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        onClick?(event)
    }

    /// A hairline the eye can aim at when ⌘-dragging items across it. Template artwork, so
    /// the menu bar tints it for light and dark alike.
    private static let dividerImage: NSImage = {
        let size = NSSize(width: 2, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
