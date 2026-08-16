//
//  HotKeyAction.swift
//  tabmenu
//

import AppKit
import Carbon.HIToolbox

/// Every globally bindable command in the app.
enum HotKeyAction: Hashable, Identifiable {
    case window(WindowAction)
    /// Restores the saved workspace layout in the given slot.
    case layout(Int)
    case showClipboard
    case switchWindows
    case togglePanel
    case toggleKeepAwake
    case toggleMicMute
    case captureText
    case searchMenus
    case quickNote
    case togglePresentation
    case rescueWindows

    static let allCases: [HotKeyAction] =
        WindowAction.allCases.map(HotKeyAction.window)
        + (0..<3).map(HotKeyAction.layout)
        + [
            .showClipboard, .switchWindows, .togglePanel, .toggleKeepAwake,
            .toggleMicMute, .captureText, .searchMenus, .quickNote,
            .togglePresentation, .rescueWindows
        ]

    /// Stable identifier used both for SwiftUI identity and defaults persistence.
    var id: String {
        switch self {
        case .window(let action): "window.\(action.rawValue)"
        case .layout(let slot): "layout.\(slot)"
        case .showClipboard: "clipboard.show"
        case .switchWindows: "switcher.show"
        case .togglePanel: "panel.toggle"
        case .toggleKeepAwake: "keepAwake.toggle"
        case .toggleMicMute: "mic.mute"
        case .captureText: "ocr.capture"
        case .searchMenus: "palette.menus"
        case .quickNote: "note.quick"
        case .togglePresentation: "presentation.toggle"
        case .rescueWindows: "window.rescue"
        }
    }

    var title: String {
        switch self {
        case .window(let action):
            action.title
        case .layout(let slot):
            String(localized: "Layout \(slot + 1)", comment: "Workspace layout slot, numbered from 1")
        case .showClipboard:
            String(localized: "Clipboard History", comment: "Shortcut name")
        case .switchWindows:
            String(localized: "Switch Windows", comment: "Shortcut name")
        case .togglePanel:
            String(localized: "Open MagicPlus", comment: "Shortcut name")
        case .toggleKeepAwake:
            String(localized: "Keep Awake", comment: "Shortcut name")
        case .toggleMicMute:
            String(localized: "Mute Microphone", comment: "Shortcut name")
        case .captureText:
            String(localized: "Capture Text (OCR)", comment: "Shortcut name")
        case .searchMenus:
            String(localized: "Search Menus", comment: "Shortcut name")
        case .quickNote:
            String(localized: "Quick Note", comment: "Shortcut name")
        case .togglePresentation:
            String(localized: "Presentation Mode", comment: "Shortcut name")
        case .rescueWindows:
            String(localized: "Rescue Windows", comment: "Shortcut name")
        }
    }

    var defaultCombo: HotKeyCombo? {
        switch self {
        case .window(let action):
            return action.defaultCombo
        case .layout(let slot):
            let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3]
            guard keyCodes.indices.contains(slot) else { return nil }
            return HotKeyCombo(keyCode: UInt16(keyCodes[slot]), modifiers: [.control, .option])
        case .showClipboard:
            return HotKeyCombo(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command, .shift])
        // ⌘Tab is owned by the system, so the switcher uses ⌥Tab.
        case .switchWindows:
            return HotKeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [.option])
        case .togglePanel:
            return HotKeyCombo(keyCode: UInt16(kVK_ANSI_M), modifiers: [.control, .option])
        case .toggleKeepAwake:
            return HotKeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .option])
        case .toggleMicMute:
            return HotKeyCombo(keyCode: UInt16(kVK_ANSI_M), modifiers: [.control, .option, .shift])
        case .captureText:
            return HotKeyCombo(keyCode: UInt16(kVK_ANSI_O), modifiers: [.control, .option])
        case .searchMenus:
            return HotKeyCombo(keyCode: UInt16(kVK_ANSI_P), modifiers: [.control, .option])
        case .quickNote:
            return HotKeyCombo(keyCode: UInt16(kVK_ANSI_N), modifiers: [.control, .option])
        case .togglePresentation:
            return HotKeyCombo(keyCode: UInt16(kVK_ANSI_P), modifiers: [.control, .option, .shift])
        case .rescueWindows:
            return HotKeyCombo(keyCode: UInt16(kVK_ANSI_R), modifiers: [.control, .option])
        }
    }
}

/// Window placement commands. Each one cycles through progressively narrower zones
/// when its shortcut is pressed repeatedly.
enum WindowAction: String, CaseIterable, Identifiable, Codable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center, restore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: String(localized: "Left", comment: "Window placement: left half of the screen")
        case .right: String(localized: "Right", comment: "Window placement: right half of the screen")
        case .top: String(localized: "Top", comment: "Window placement: top half of the screen")
        case .bottom: String(localized: "Bottom", comment: "Window placement: bottom half of the screen")
        case .topLeft: String(localized: "Top Left", comment: "Window placement: top-left quarter")
        case .topRight: String(localized: "Top Right", comment: "Window placement: top-right quarter")
        case .bottomLeft: String(localized: "Bottom Left", comment: "Window placement: bottom-left quarter")
        case .bottomRight: String(localized: "Bottom Right", comment: "Window placement: bottom-right quarter")
        case .maximize: String(localized: "Maximize", comment: "Window placement: fill the screen")
        case .center: String(localized: "Center", comment: "Window placement: centred on screen")
        case .restore: String(localized: "Restore", comment: "Window placement: back to its previous frame")
        }
    }

    var symbolName: String {
        switch self {
        case .left: "rectangle.lefthalf.filled"
        case .right: "rectangle.righthalf.filled"
        case .top: "rectangle.tophalf.filled"
        case .bottom: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .maximize: "rectangle.fill"
        case .center: "rectangle.center.inset.filled"
        case .restore: "arrow.uturn.backward"
        }
    }

    /// Zones visited in order on repeated activation of the same shortcut.
    var cycle: [WindowZone] {
        switch self {
        case .left: [.leftHalf, .leftTwoThirds, .leftThird]
        case .right: [.rightHalf, .rightTwoThirds, .rightThird]
        case .top: [.topHalf, .topTwoThirds, .topThird]
        case .bottom: [.bottomHalf, .bottomTwoThirds, .bottomThird]
        case .topLeft: [.topLeftQuarter]
        case .topRight: [.topRightQuarter]
        case .bottomLeft: [.bottomLeftQuarter]
        case .bottomRight: [.bottomRightQuarter]
        case .maximize: [.maximize]
        case .center: [.center, .centerThird]
        case .restore: []
        }
    }

    var defaultCombo: HotKeyCombo? {
        let controlOption: NSEvent.ModifierFlags = [.control, .option]
        switch self {
        case .left: return HotKeyCombo(keyCode: UInt16(kVK_LeftArrow), modifiers: controlOption)
        case .right: return HotKeyCombo(keyCode: UInt16(kVK_RightArrow), modifiers: controlOption)
        case .top: return HotKeyCombo(keyCode: UInt16(kVK_UpArrow), modifiers: controlOption)
        case .bottom: return HotKeyCombo(keyCode: UInt16(kVK_DownArrow), modifiers: controlOption)
        case .topLeft: return HotKeyCombo(keyCode: UInt16(kVK_ANSI_U), modifiers: controlOption)
        case .topRight: return HotKeyCombo(keyCode: UInt16(kVK_ANSI_I), modifiers: controlOption)
        case .bottomLeft: return HotKeyCombo(keyCode: UInt16(kVK_ANSI_J), modifiers: controlOption)
        case .bottomRight: return HotKeyCombo(keyCode: UInt16(kVK_ANSI_K), modifiers: controlOption)
        case .maximize: return HotKeyCombo(keyCode: UInt16(kVK_Return), modifiers: controlOption)
        case .center: return HotKeyCombo(keyCode: UInt16(kVK_ANSI_C), modifiers: controlOption)
        case .restore: return HotKeyCombo(keyCode: UInt16(kVK_ANSI_Z), modifiers: controlOption)
        }
    }
}
