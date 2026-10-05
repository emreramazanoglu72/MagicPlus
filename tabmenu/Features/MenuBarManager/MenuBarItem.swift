//
//  MenuBarItem.swift
//  tabmenu
//

import AppKit
import CoreGraphics

/// One item in the system menu bar, read from the window server rather than from the app
/// that owns it. Everything the manager knows about an item comes from here.
struct MenuBarItem: Identifiable, Hashable, Sendable {
    let windowID: CGWindowID
    let processIdentifier: pid_t
    let ownerName: String
    let title: String
    /// Screen coordinates with a top-left origin, the space `CGEvent` also posts into.
    let frame: CGRect
    let isOnScreen: Bool

    var id: CGWindowID { windowID }

    /// Survives relaunches of the owning app, unlike the window ID, so cached images and
    /// section assignments stay attached to the right item.
    var key: String { "\(ownerName)\u{1}\(title)" }

    var displayName: String { MenuBarItemNaming.displayName(owner: ownerName, title: title) }

    var searchText: String { "\(displayName) \(ownerName) \(title)" }

    var application: NSRunningApplication? {
        NSRunningApplication(processIdentifier: processIdentifier)
    }

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// System items report the internal name of their module — "BentoBox" for Control Center —
/// which means nothing in a list, so the known ones are named and the rest are split on
/// their capitals.
enum MenuBarItemNaming {
    static func displayName(owner: String, title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return owner }
        if let known = knownTitles[title] { return known }
        let split = splitOnCapitals(title)
        return split.isEmpty ? owner : split
    }

    /// "NowPlaying" reads as "Now Playing"; anything already spaced is left alone.
    static func splitOnCapitals(_ title: String) -> String {
        guard !title.contains(" ") else { return title }
        var words: [String] = []
        var current = ""
        for character in title {
            if character.isUppercase, !current.isEmpty, current.last?.isUppercase == false {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    private static let knownTitles: [String: String] = [
        "BentoBox": String(localized: "Control Center", comment: "Menu bar item name"),
        "Clock": String(localized: "Clock", comment: "Menu bar item name"),
        "WiFi": String(localized: "Wi-Fi", comment: "Menu bar item name"),
        "BatteryIcon": String(localized: "Battery", comment: "Menu bar item name"),
        "NowPlaying": String(localized: "Now Playing", comment: "Menu bar item name"),
        "AudioVideoModule": String(localized: "Sound", comment: "Menu bar item name"),
        "Display": String(localized: "Display", comment: "Menu bar item name"),
        "FocusModes": String(localized: "Focus", comment: "Menu bar item name"),
        "ScreenMirroring": String(localized: "Screen Mirroring", comment: "Menu bar item name"),
        "Bluetooth": String(localized: "Bluetooth", comment: "Menu bar item name"),
        "UserSwitcher": String(localized: "Fast User Switching", comment: "Menu bar item name"),
        "Siri": String(localized: "Siri", comment: "Menu bar item name"),
        "TimeMachine": String(localized: "Time Machine", comment: "Menu bar item name"),
        "KeyboardBrightness": String(localized: "Keyboard Brightness", comment: "Menu bar item name"),
        "AccessibilityShortcuts": String(localized: "Accessibility Shortcuts", comment: "Menu bar item name"),
        "MusicRecognition": String(localized: "Music Recognition", comment: "Menu bar item name"),
        "VPN": String(localized: "VPN", comment: "Menu bar item name"),
        "StageManager": String(localized: "Stage Manager", comment: "Menu bar item name")
    ]
}

/// Reads the menu bar's contents from the window server. Status items live on their own
/// window layer, which is what makes every app's items findable without talking to them.
enum MenuBarItemLister {
    private static var statusLayer: Int { Int(CGWindowLevelForKey(.statusWindow)) }
    private static var popUpMenuLayer: Int { Int(CGWindowLevelForKey(.popUpMenuWindow)) }

    /// Menu bar item windows are as tall as the bar itself. The range covers both the 24pt
    /// bar of an external display and the taller one on built-in notched screens.
    private static let heightRange: ClosedRange<CGFloat> = 18...48

    /// Every item currently in the bar, left to right. Hidden items are included: they are
    /// pushed out of the bar rather than destroyed, so the window server still lists them.
    static func items() -> [MenuBarItem] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windows
            .compactMap { item(from: $0) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// True while any other app is showing a menu. Rehiding then would yank the item the
    /// menu belongs to out from under it, closing the menu the user just opened.
    static func isPopUpMenuOpen() -> Bool {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= popUpMenuLayer else {
                return false
            }
            let pid = window[kCGWindowOwnerPID as String] as? pid_t
            return pid != ownProcessIdentifier
        }
    }

    private static func item(from window: [String: Any]) -> MenuBarItem? {
        guard let layer = window[kCGWindowLayer as String] as? Int, layer == statusLayer,
              let windowID = window[kCGWindowNumber as String] as? CGWindowID,
              let processIdentifier = window[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width >= 1, heightRange.contains(frame.height)
        else { return nil }

        return MenuBarItem(
            windowID: windowID,
            processIdentifier: processIdentifier,
            ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
            title: window[kCGWindowName as String] as? String ?? "",
            frame: frame,
            isOnScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false
        )
    }
}
