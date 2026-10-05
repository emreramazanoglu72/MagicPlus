//
//  MenuBarSection.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// The three slices the menu bar is cut into. Which slice an item is in is decided by where
/// it sits relative to the app's divider items — the same thing the menu bar itself uses to
/// lay the row out — so dragging an item across a divider is all it takes to reassign it.
enum MenuBarSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case visible
    case hidden
    case alwaysHidden

    var id: String { rawValue }

    var isCollapsible: Bool { self != .visible }

    var title: String {
        switch self {
        case .visible: String(localized: "Visible", comment: "Menu bar section: items always on show")
        case .hidden: String(localized: "Hidden", comment: "Menu bar section: items revealed on demand")
        case .alwaysHidden: String(localized: "Always Hidden", comment: "Menu bar section: items kept out of the way")
        }
    }

    var symbolName: String {
        switch self {
        case .visible: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "eye.slash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .visible: Accent.menuBar
        case .hidden: .orange
        case .alwaysHidden: .pink
        }
    }
}

/// When a revealed section folds itself away again.
enum MenuBarRehideStrategy: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Stays open until it is toggled again.
    case never
    /// Folds away once the pointer drops out of the menu bar.
    case pointerLeaves
    /// Folds away when another app comes to the front.
    case focusedApp
    /// Folds away after a fixed delay.
    case timed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: String(localized: "Never", comment: "Rehide strategy")
        case .pointerLeaves: String(localized: "When the pointer leaves the menu bar", comment: "Rehide strategy")
        case .focusedApp: String(localized: "When another app comes to the front", comment: "Rehide strategy")
        case .timed: String(localized: "After a delay", comment: "Rehide strategy")
        }
    }
}

/// Pure geometry, kept separate from the status items so it can be reasoned about — and
/// tested — without a menu bar.
enum MenuBarLayout {
    /// An item belongs to whichever section its left edge falls into. The always-hidden
    /// boundary is clamped to the hidden one so a divider the user dragged into the wrong
    /// order cannot produce a section that swallows the whole bar.
    static func section(
        itemMinX: CGFloat,
        hiddenDividerMinX: CGFloat?,
        alwaysHiddenDividerMinX: CGFloat?
    ) -> MenuBarSection {
        if let alwaysHiddenDividerMinX {
            let boundary = min(alwaysHiddenDividerMinX, hiddenDividerMinX ?? alwaysHiddenDividerMinX)
            if itemMinX < boundary { return .alwaysHidden }
        }
        guard let hiddenDividerMinX else { return .visible }
        return itemMinX < hiddenDividerMinX ? .hidden : .visible
    }
}

/// Where the menu bar is on each display.
enum MenuBarGeometry {
    /// The bar's own rectangle, in AppKit coordinates. Falls back to the status bar's
    /// thickness when the bar is set to hide automatically and claims no inset.
    static func menuBarFrame(for screen: NSScreen) -> CGRect {
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        return CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - height,
            width: screen.frame.width,
            height: height
        )
    }

    /// True while the pointer is over any display's menu bar.
    static func isInsideMenuBar(_ location: CGPoint, screens: [NSScreen] = NSScreen.screens) -> Bool {
        screens.contains { menuBarFrame(for: $0).contains(location) }
    }

    /// The menu bar is gone in full screen, which is when overlays have to get out of the way.
    static func isMenuBarVisible(on screen: NSScreen) -> Bool {
        screen.frame.maxY - screen.visibleFrame.maxY > 1
    }

    static func screenContainingPointer(_ location: CGPoint = NSEvent.mouseLocation) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }
}
