//
//  Preferences.swift
//  tabmenu
//

import Foundation
import Observation

/// Single source of truth for user settings, mirrored into `UserDefaults` on every change.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let launchAtLogin = "general.launchAtLogin"
        static let menuBarMetric = "general.menuBarMetric"
        static let isClipboardEnabled = "clipboard.enabled"
        static let historyLimit = "clipboard.historyLimit"
        static let ignoredBundleIDs = "clipboard.ignoredBundleIDs"
        static let pastesAutomatically = "clipboard.pastesAutomatically"
        static let windowGap = "window.gap"
        static let shortcuts = "shortcuts"
        static let isDockPreviewEnabled = "dock.previewEnabled"
        static let dockHoverDelay = "dock.hoverDelay"
        static let showsWindowThumbnails = "preview.showsThumbnails"
        static let switcherLayout = "switcher.layout"
        static let isNotchPanelEnabled = "notch.enabled"
        static let hasCompletedOnboarding = "onboarding.completed"
        static let isDragSnapEnabled = "window.dragSnap"
        static let capturesScreenshots = "shelf.capturesScreenshots"
        static let skipsSensitiveContent = "clipboard.skipsSensitive"
        static let mixerVolumes = "mixer.volumes"
        static let keepAwakeDuration = "keepAwake.duration"
        static let keepsDisplayAwake = "keepAwake.keepsDisplayAwake"
        static let resumesKeepAwakeAtLaunch = "keepAwake.resumesAtLaunch"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            LaunchAtLogin.setEnabled(launchAtLogin)
        }
    }

    var menuBarMetric: MenuBarMetric {
        didSet { defaults.set(menuBarMetric.rawValue, forKey: Key.menuBarMetric) }
    }

    var isClipboardEnabled: Bool {
        didSet { defaults.set(isClipboardEnabled, forKey: Key.isClipboardEnabled) }
    }

    /// Number of unpinned entries kept in history.
    var historyLimit: Int {
        didSet { defaults.set(historyLimit, forKey: Key.historyLimit) }
    }

    /// Bundle identifiers whose clipboard writes are never recorded, for password managers.
    var ignoredBundleIDs: [String] {
        didSet { defaults.set(ignoredBundleIDs, forKey: Key.ignoredBundleIDs) }
    }

    var pastesAutomatically: Bool {
        didSet { defaults.set(pastesAutomatically, forKey: Key.pastesAutomatically) }
    }

    /// Padding applied around every tiled window, in points.
    var windowGap: Double {
        didSet { defaults.set(windowGap, forKey: Key.windowGap) }
    }

    /// Live window previews when hovering a Dock icon.
    var isDockPreviewEnabled: Bool {
        didSet { defaults.set(isDockPreviewEnabled, forKey: Key.isDockPreviewEnabled) }
    }

    /// Seconds the pointer must rest on a Dock icon before previews appear.
    var dockHoverDelay: Double {
        didSet { defaults.set(dockHoverDelay, forKey: Key.dockHoverDelay) }
    }

    /// Captured window images. Requires Screen Recording; without it previews fall back to
    /// application icons.
    var showsWindowThumbnails: Bool {
        didSet { defaults.set(showsWindowThumbnails, forKey: Key.showsWindowThumbnails) }
    }

    var switcherLayout: SwitcherLayout {
        didSet { defaults.set(switcherLayout.rawValue, forKey: Key.switcherLayout) }
    }

    /// Panel that drops out of the notch, carrying the file shelf and playback controls.
    var isNotchPanelEnabled: Bool {
        didSet { defaults.set(isNotchPanelEnabled, forKey: Key.isNotchPanelEnabled) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// Snap a window by dragging it against a screen edge.
    var isDragSnapEnabled: Bool {
        didSet { defaults.set(isDragSnapEnabled, forKey: Key.isDragSnapEnabled) }
    }

    /// New screenshots land on the notch shelf automatically.
    var capturesScreenshots: Bool {
        didSet { defaults.set(capturesScreenshots, forKey: Key.capturesScreenshots) }
    }

    /// Card numbers, API keys and tokens are never recorded into history.
    var skipsSensitiveContent: Bool {
        didSet { defaults.set(skipsSensitiveContent, forKey: Key.skipsSensitiveContent) }
    }

    /// Per-application mixer volumes, keyed by bundle identifier. 1.0 entries are removed.
    private(set) var mixerVolumes: [String: Double] {
        didSet { defaults.set(mixerVolumes, forKey: Key.mixerVolumes) }
    }

    func setMixerVolume(_ volume: Double, for key: String) {
        if volume >= 0.999 {
            mixerVolumes.removeValue(forKey: key)
        } else {
            mixerVolumes[key] = volume
        }
    }

    /// How long the next keep-awake session runs before switching itself off.
    var keepAwakeDuration: KeepAwakeDuration {
        didSet { defaults.set(keepAwakeDuration.rawValue, forKey: Key.keepAwakeDuration) }
    }

    /// Whether keep-awake also holds the display on. Off keeps the Mac running with a dark
    /// screen, which still locks when the display sleeps.
    var keepsDisplayAwake: Bool {
        didSet { defaults.set(keepsDisplayAwake, forKey: Key.keepsDisplayAwake) }
    }

    var resumesKeepAwakeAtLaunch: Bool {
        didSet { defaults.set(resumesKeepAwakeAtLaunch, forKey: Key.resumesKeepAwakeAtLaunch) }
    }

    private(set) var shortcuts: [String: HotKeyCombo] {
        didSet {
            guard let data = try? JSONEncoder().encode(shortcuts) else { return }
            defaults.set(data, forKey: Key.shortcuts)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isClipboardEnabled: true,
            Key.historyLimit: 200,
            Key.pastesAutomatically: true,
            Key.windowGap: 6.0,
            Key.menuBarMetric: MenuBarMetric.none.rawValue,
            Key.isDockPreviewEnabled: true,
            Key.dockHoverDelay: 0.25,
            Key.showsWindowThumbnails: true,
            Key.switcherLayout: SwitcherLayout.grid.rawValue,
            Key.isNotchPanelEnabled: true,
            Key.isDragSnapEnabled: true,
            Key.capturesScreenshots: true,
            Key.skipsSensitiveContent: true,
            Key.keepAwakeDuration: KeepAwakeDuration.indefinitely.rawValue,
            Key.keepsDisplayAwake: true
        ])

        launchAtLogin = LaunchAtLogin.isEnabled
        menuBarMetric = MenuBarMetric(rawValue: defaults.string(forKey: Key.menuBarMetric) ?? "") ?? .none
        isClipboardEnabled = defaults.bool(forKey: Key.isClipboardEnabled)
        historyLimit = defaults.integer(forKey: Key.historyLimit)
        ignoredBundleIDs = defaults.stringArray(forKey: Key.ignoredBundleIDs) ?? Preferences.defaultIgnoredBundleIDs
        pastesAutomatically = defaults.bool(forKey: Key.pastesAutomatically)
        windowGap = defaults.double(forKey: Key.windowGap)
        isDockPreviewEnabled = defaults.bool(forKey: Key.isDockPreviewEnabled)
        dockHoverDelay = defaults.double(forKey: Key.dockHoverDelay)
        showsWindowThumbnails = defaults.bool(forKey: Key.showsWindowThumbnails)
        switcherLayout = SwitcherLayout(rawValue: defaults.string(forKey: Key.switcherLayout) ?? "") ?? .grid
        isNotchPanelEnabled = defaults.bool(forKey: Key.isNotchPanelEnabled)
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        isDragSnapEnabled = defaults.bool(forKey: Key.isDragSnapEnabled)
        capturesScreenshots = defaults.bool(forKey: Key.capturesScreenshots)
        skipsSensitiveContent = defaults.bool(forKey: Key.skipsSensitiveContent)
        mixerVolumes = (defaults.dictionary(forKey: Key.mixerVolumes) as? [String: Double]) ?? [:]
        keepAwakeDuration = KeepAwakeDuration(
            rawValue: defaults.string(forKey: Key.keepAwakeDuration) ?? ""
        ) ?? .indefinitely
        keepsDisplayAwake = defaults.bool(forKey: Key.keepsDisplayAwake)
        resumesKeepAwakeAtLaunch = defaults.bool(forKey: Key.resumesKeepAwakeAtLaunch)

        if let data = defaults.data(forKey: Key.shortcuts),
           let stored = try? JSONDecoder().decode([String: HotKeyCombo].self, from: data) {
            shortcuts = stored
        } else {
            shortcuts = Preferences.defaultShortcuts
        }
    }

    // MARK: - Shortcuts

    func shortcut(for action: HotKeyAction) -> HotKeyCombo? {
        shortcuts[action.id]
    }

    func setShortcut(_ combo: HotKeyCombo?, for action: HotKeyAction) {
        if let combo {
            shortcuts[action.id] = combo
        } else {
            shortcuts.removeValue(forKey: action.id)
        }
    }

    func resetShortcutsToDefaults() {
        shortcuts = Preferences.defaultShortcuts
    }

    private static var defaultShortcuts: [String: HotKeyCombo] {
        HotKeyAction.allCases.reduce(into: [:]) { result, action in
            result[action.id] = action.defaultCombo
        }
    }

    /// Well-known credential managers are excluded from history out of the box.
    private static let defaultIgnoredBundleIDs = [
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop"
    ]
}

enum SwitcherLayout: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: String(localized: "Previews", comment: "Switcher layout showing window thumbnails")
        case .list: String(localized: "Compact list", comment: "Switcher layout showing a plain list")
        }
    }

    var symbolName: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case none
    case cpu
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "Icon only", comment: "Menu bar shows no metric")
        case .cpu: String(localized: "CPU load", comment: "Menu bar metric option")
        case .memory: String(localized: "Memory used", comment: "Menu bar metric option")
        }
    }
}
