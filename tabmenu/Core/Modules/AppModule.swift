//
//  AppModule.swift
//  tabmenu
//

import Foundation

/// One switchable part of the app.
///
/// MagicPlus is a dozen small utilities sharing a menu bar item, and until now each one decided
/// for itself whether it could be turned off: five had a switch of their own in whichever
/// settings tab they lived in, and the rest could not be turned off at all. That is the wrong
/// shape for an app people install for two of its features.
///
/// A module is therefore a first-class thing rather than a checkbox. It knows what it is called,
/// what it does, and — the part that makes the switch mean something — **which global shortcuts
/// belong to it**, so a module that is off holds none of them. Switching one off is expected to
/// release what it was holding: its samplers, its observers, its status items and its keys. A
/// toggle that only hides an interface is a lie about what the machine is doing.
///
/// The switches that already existed keep their own preference keys, so a choice made before any
/// of this existed is still the one being read. There is no second copy of that truth.
nonisolated enum AppModule: String, CaseIterable, Identifiable, Sendable {
    case windows
    case windowSwitcher
    case clipboard
    case notch
    case downloads
    case menuBar
    case dockPreviews
    case dock
    case menuSearch
    case quickNote
    case textCapture
    case microphone
    case keepAwake
    case presentation
    case systemMonitor
    case hardware

    var id: String { rawValue }

    /// Preference key. The five that shipped with a switch keep theirs; the rest get one named
    /// after the module.
    var preferenceKey: String {
        switch self {
        case .clipboard: "clipboard.enabled"
        case .notch: "notch.enabled"
        case .downloads: "downloads.enabled"
        case .menuBar: "menuBar.managerEnabled"
        case .dockPreviews: "dock.previewEnabled"
        default: "module.\(rawValue)"
        }
    }

    var title: String {
        switch self {
        case .windows: String(localized: "Window Manager", comment: "Module name")
        case .windowSwitcher: String(localized: "Window Switcher", comment: "Module name")
        case .clipboard: String(localized: "Clipboard History", comment: "Module name")
        case .notch: String(localized: "Notch Panel", comment: "Module name")
        case .downloads: String(localized: "Downloads", comment: "Module name")
        case .menuBar: String(localized: "Menu Bar Manager", comment: "Module name")
        case .dockPreviews: String(localized: "Dock Previews", comment: "Module name")
        case .dock: String(localized: "Dock Settings", comment: "Module name")
        case .menuSearch: String(localized: "Menu Search", comment: "Module name")
        case .quickNote: String(localized: "Quick Note", comment: "Module name")
        case .textCapture: String(localized: "Text Capture", comment: "Module name")
        case .microphone: String(localized: "Microphone", comment: "Module name")
        case .keepAwake: String(localized: "Keep Awake", comment: "Module name")
        case .presentation: String(localized: "Presentation Mode", comment: "Module name")
        case .systemMonitor: String(localized: "System Monitor", comment: "Module name")
        case .hardware: String(localized: "Sensors & Battery", comment: "Module name")
        }
    }

    /// What it does, and where the cost is. A switch is only informed if it says what turning it
    /// off gives back.
    var summary: String {
        switch self {
        case .windows:
            String(localized: "Tiling commands, saved layouts, per-app rules and snapping to screen edges.", comment: "Module summary")
        case .windowSwitcher:
            String(localized: "A panel that cycles through open windows with previews.", comment: "Module summary")
        case .clipboard:
            String(localized: "Keeps what you copy, searchable and pinnable. Polls the pasteboard.", comment: "Module summary")
        case .notch:
            String(localized: "The island: what is playing, the file shelf, the download queue and transient notices.", comment: "Module summary")
        case .downloads:
            String(localized: "A download queue with resume, the link grabber and the browser extension bridge.", comment: "Module summary")
        case .menuBar:
            String(localized: "Folds menu bar items away behind a chevron, with search and appearance.", comment: "Module summary")
        case .dockPreviews:
            String(localized: "Live window previews when the pointer rests on a Dock icon.", comment: "Module summary")
        case .dock:
            String(localized: "The Dock settings Apple ships but never shows: reveal delay, bouncing, separators.", comment: "Module summary")
        case .menuSearch:
            String(localized: "A palette over the frontmost app's menus.", comment: "Module summary")
        case .quickNote:
            String(localized: "Captures a thought to a file on the shelf without opening an editor.", comment: "Module summary")
        case .textCapture:
            String(localized: "Reads text off the screen and copies it.", comment: "Module summary")
        case .microphone:
            String(localized: "Mutes the input device by shortcut, and shows when something is listening.", comment: "Module summary")
        case .keepAwake:
            String(localized: "Holds off sleep for as long as you choose.", comment: "Module summary")
        case .presentation:
            String(localized: "Silences notices and keeps the display on while you present.", comment: "Module summary")
        case .systemMonitor:
            String(localized: "CPU, memory, disk and network readings, and the menu bar metric.", comment: "Module summary")
        case .hardware:
            String(localized: "Temperatures, fans, battery condition and the charge limit.", comment: "Module summary")
        }
    }

    var symbolName: String {
        switch self {
        case .windows: "macwindow.on.rectangle"
        case .windowSwitcher: "square.stack"
        case .clipboard: "doc.on.clipboard"
        case .notch: "rectangle.topthird.inset.filled"
        case .downloads: "arrow.down.circle"
        case .menuBar: "menubar.rectangle"
        case .dockPreviews: "dock.rectangle"
        case .dock: "dock.arrow.up.rectangle"
        case .menuSearch: "filemenu.and.selection"
        case .quickNote: "square.and.pencil"
        case .textCapture: "text.viewfinder"
        case .microphone: "mic"
        case .keepAwake: "cup.and.saucer"
        case .presentation: "person.and.background.dotted"
        case .systemMonitor: "waveform.path.ecg"
        case .hardware: "thermometer.medium"
        }
    }

    /// The macOS permissions this module cannot work without.
    ///
    /// Kept here rather than in the permission catalog because the question is always "what does
    /// this feature need", never "who might want this permission". Asking for the Camera on behalf
    /// of a module that is switched off is how an app earns a reputation for wanting too much.
    var requiredPermissions: [PermissionKind] {
        switch self {
        case .windows, .menuBar, .menuSearch: [.accessibility]
        case .clipboard: [.accessibility]
        case .windowSwitcher, .dockPreviews: [.accessibility, .screenRecording]
        case .textCapture: [.screenRecording]
        case .notch: [.calendar, .camera, .automation]
        case .downloads: [.automation]
        // Nothing to grant: these are the Dock's own preferences, and this app is the user.
        case .dock: []
        case .quickNote, .microphone, .keepAwake, .presentation, .systemMonitor, .hardware: []
        }
    }

    /// Every permission some switched-on module actually needs, in the catalog's own order.
    ///
    /// Takes the switch as a function so this stays answerable without a live `Preferences`.
    static func permissionsNeeded(where isEnabled: (AppModule) -> Bool) -> [PermissionKind] {
        let needed = Set(allCases.filter(isEnabled).flatMap(\.requiredPermissions))
        return PermissionKind.allCases.filter(needed.contains)
    }

    /// The module a shortcut belongs to, or `nil` when it belongs to the app rather than to any
    /// one part of it.
    ///
    /// Exhaustive on purpose: a new action cannot be added without deciding this, and a module
    /// that is off must not keep a system-wide key registered on behalf of something the user has
    /// switched off.
    static func owner(of action: HotKeyAction) -> AppModule? {
        switch action {
        case .window, .layout, .rescueWindows: .windows
        case .switchWindows: .windowSwitcher
        case .showClipboard: .clipboard
        case .searchMenus: .menuSearch
        case .quickNote: .quickNote
        case .captureText: .textCapture
        case .toggleMicMute: .microphone
        case .toggleKeepAwake: .keepAwake
        case .togglePresentation: .presentation
        case .toggleHiddenItems, .searchMenuBarItems: .menuBar
        // Opening the app's own popover is not a feature that can be switched off.
        case .togglePanel: nil
        }
    }
}
