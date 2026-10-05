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
        static let isMenuBarManagerEnabled = "menuBar.managerEnabled"
        static let isHiddenSectionRevealed = "menuBar.hiddenSectionRevealed"
        static let usesAlwaysHiddenSection = "menuBar.alwaysHiddenSection"
        static let usesHiddenItemsBar = "menuBar.usesHiddenItemsBar"
        static let menuBarShowsOnHover = "menuBar.showsOnHover"
        static let menuBarRehideStrategy = "menuBar.rehideStrategy"
        static let menuBarRehideDelay = "menuBar.rehideDelay"
        static let menuBarTintStyle = "menuBar.tintStyle"
        static let menuBarTintColor = "menuBar.tintColor"
        static let menuBarTintOpacity = "menuBar.tintOpacity"
        static let menuBarShowsBorder = "menuBar.showsBorder"
        static let isChargeLimitEnabled = "battery.chargeLimitEnabled"
        static let chargeLimitPercentage = "battery.chargeLimitPercentage"
        static let isDownloadManagerEnabled = "downloads.enabled"
        static let downloadFolderPath = "downloads.folder"
        static let maximumConcurrentDownloads = "downloads.maximumConcurrent"
        static let grabsLinksFromClipboard = "downloads.grabsClipboardLinks"
        static let watchesBrowserTabs = "downloads.watchesBrowserTabs"
        static let sortsDownloadsByKind = "downloads.sortsByKind"
        static let mediaToolPath = "downloads.mediaToolPath"
        static let preferredMediaQuality = "downloads.mediaQuality"
        static let mediaCookieSource = "downloads.mediaCookieSource"
        static let isBrowserBridgeEnabled = "downloads.browserBridge"
        static let disabledModules = "modules.disabled"
        static let isCustomDockEnabled = "dock.customEnabled"
        static let dockStyle = "dock.style"
        static let dockPins = "dock.pins"
        static let dockPinsSeeded = "dock.pinsSeeded"
        static let agentProvider = "agent.provider"
        static let agentModel = "agent.model"
        static let agentCloudflareAccount = "agent.cloudflareAccount"
        static let isAgentEnabled = "agent.enabled"
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

    /// Splits the menu bar into sections and adds the chevron that folds them away.
    var isMenuBarManagerEnabled: Bool {
        didSet { defaults.set(isMenuBarManagerEnabled, forKey: Key.isMenuBarManagerEnabled) }
    }

    /// Whether the hidden section was on show when the app was last quit. It starts out
    /// revealed, so enabling the feature never makes an item disappear before the user has
    /// decided which ones belong there.
    var isHiddenSectionRevealed: Bool {
        didSet { defaults.set(isHiddenSectionRevealed, forKey: Key.isHiddenSectionRevealed) }
    }

    /// A second, deeper section for items that should only ever be reached deliberately.
    var usesAlwaysHiddenSection: Bool {
        didSet { defaults.set(usesAlwaysHiddenSection, forKey: Key.usesAlwaysHiddenSection) }
    }

    /// Show hidden items in a strip under the menu bar instead of folding them back into it.
    var usesHiddenItemsBar: Bool {
        didSet { defaults.set(usesHiddenItemsBar, forKey: Key.usesHiddenItemsBar) }
    }

    var menuBarShowsOnHover: Bool {
        didSet { defaults.set(menuBarShowsOnHover, forKey: Key.menuBarShowsOnHover) }
    }

    var menuBarRehideStrategy: MenuBarRehideStrategy {
        didSet { defaults.set(menuBarRehideStrategy.rawValue, forKey: Key.menuBarRehideStrategy) }
    }

    /// Seconds a revealed section stays open under the timed strategy.
    var menuBarRehideDelay: Double {
        didSet { defaults.set(menuBarRehideDelay, forKey: Key.menuBarRehideDelay) }
    }

    var menuBarTintStyle: MenuBarTintStyle {
        didSet { defaults.set(menuBarTintStyle.rawValue, forKey: Key.menuBarTintStyle) }
    }

    /// Tint colour as six hex digits.
    var menuBarTintColor: String {
        didSet { defaults.set(menuBarTintColor, forKey: Key.menuBarTintColor) }
    }

    var menuBarTintOpacity: Double {
        didSet { defaults.set(menuBarTintOpacity, forKey: Key.menuBarTintOpacity) }
    }

    var menuBarShowsBorder: Bool {
        didSet { defaults.set(menuBarShowsBorder, forKey: Key.menuBarShowsBorder) }
    }

    /// Holds the battery at `chargeLimitPercentage` instead of letting it fill. Needs the
    /// privileged helper, and only holds while MagicPlus is running.
    var isChargeLimitEnabled: Bool {
        didSet { defaults.set(isChargeLimitEnabled, forKey: Key.isChargeLimitEnabled) }
    }

    /// Where charging stops, as a percentage. 80 is the level Apple's own optimised charging
    /// parks at, and the one most battery research points to.
    var chargeLimitPercentage: Int {
        didSet { defaults.set(chargeLimitPercentage, forKey: Key.chargeLimitPercentage) }
    }

    /// The download queue, its link grabber and the island's downloads pane.
    var isDownloadManagerEnabled: Bool {
        didSet { defaults.set(isDownloadManagerEnabled, forKey: Key.isDownloadManagerEnabled) }
    }

    /// Where downloads land. Empty means the system Downloads folder, which is what almost
    /// everyone wants and survives the folder being moved.
    var downloadFolderPath: String {
        didSet { defaults.set(downloadFolderPath, forKey: Key.downloadFolderPath) }
    }

    /// How many transfers run at once. The rest wait their turn.
    var maximumConcurrentDownloads: Int {
        didSet { defaults.set(maximumConcurrentDownloads, forKey: Key.maximumConcurrentDownloads) }
    }

    /// Copying a link offers to download it.
    var grabsLinksFromClipboard: Bool {
        didSet { defaults.set(grabsLinksFromClipboard, forKey: Key.grabsLinksFromClipboard) }
    }

    /// Watches the front browser tab for media pages and file links.
    ///
    /// On by default, because a download manager that cannot see the page you are on is half a
    /// feature — but it reads the address bar and nothing else, it needs Automation permission
    /// per browser, and a refusal is reported in Settings rather than leaving it looking broken.
    var watchesBrowserTabs: Bool {
        didSet { defaults.set(watchesBrowserTabs, forKey: Key.watchesBrowserTabs) }
    }

    /// Files into per-kind sub-folders of the download folder.
    var sortsDownloadsByKind: Bool {
        didSet { defaults.set(sortsDownloadsByKind, forKey: Key.sortsDownloadsByKind) }
    }

    /// Path to the external media helper. Empty means "look in the usual places".
    var mediaToolPath: String {
        didSet { defaults.set(mediaToolPath, forKey: Key.mediaToolPath) }
    }

    /// Quality pre-selected in the prompt, which is the last one the user picked.
    var preferredMediaQuality: MediaQuality {
        didSet { defaults.set(preferredMediaQuality.rawValue, forKey: Key.preferredMediaQuality) }
    }

    /// Listens on a loopback port for the browser extension. Nothing can use it until the
    /// user has approved a pairing dialog, so listening on its own gives nothing away.
    var isBrowserBridgeEnabled: Bool {
        didSet { defaults.set(isBrowserBridgeEnabled, forKey: Key.isBrowserBridgeEnabled) }
    }

    /// Browser whose cookies the media helper may read. Off unless the user says otherwise:
    /// it hands their signed-in session to another program.
    var mediaCookieSource: MediaCookieSource {
        didSet { defaults.set(mediaCookieSource.rawValue, forKey: Key.mediaCookieSource) }
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
            Key.keepsDisplayAwake: true,
            Key.isMenuBarManagerEnabled: true,
            Key.isHiddenSectionRevealed: true,
            Key.usesAlwaysHiddenSection: false,
            Key.usesHiddenItemsBar: false,
            Key.menuBarShowsOnHover: false,
            Key.menuBarRehideStrategy: MenuBarRehideStrategy.pointerLeaves.rawValue,
            Key.menuBarRehideDelay: 15.0,
            Key.menuBarTintStyle: MenuBarTintStyle.none.rawValue,
            Key.menuBarTintColor: "3478F6",
            Key.menuBarTintOpacity: 0.18,
            Key.menuBarShowsBorder: false,
            Key.isChargeLimitEnabled: false,
            Key.chargeLimitPercentage: 80,
            Key.isDownloadManagerEnabled: true,
            Key.maximumConcurrentDownloads: 3,
            Key.grabsLinksFromClipboard: true,
            Key.watchesBrowserTabs: true,
            Key.sortsDownloadsByKind: false,
            Key.preferredMediaQuality: MediaQuality.p1080.rawValue,
            Key.mediaCookieSource: MediaCookieSource.none.rawValue,
            Key.isBrowserBridgeEnabled: true,
            Key.agentProvider: AgentProvider.anthropic.rawValue,
            Key.isAgentEnabled: false
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
        agentProvider = defaults.string(forKey: Key.agentProvider) ?? AgentProvider.anthropic.rawValue
        agentModel = defaults.string(forKey: Key.agentModel) ?? ""
        agentCloudflareAccount = defaults.string(forKey: Key.agentCloudflareAccount) ?? ""
        isAgentEnabled = defaults.bool(forKey: Key.isAgentEnabled)
        keepAwakeDuration = KeepAwakeDuration(
            rawValue: defaults.string(forKey: Key.keepAwakeDuration) ?? ""
        ) ?? .indefinitely
        keepsDisplayAwake = defaults.bool(forKey: Key.keepsDisplayAwake)
        resumesKeepAwakeAtLaunch = defaults.bool(forKey: Key.resumesKeepAwakeAtLaunch)
        isMenuBarManagerEnabled = defaults.bool(forKey: Key.isMenuBarManagerEnabled)
        isHiddenSectionRevealed = defaults.bool(forKey: Key.isHiddenSectionRevealed)
        usesAlwaysHiddenSection = defaults.bool(forKey: Key.usesAlwaysHiddenSection)
        usesHiddenItemsBar = defaults.bool(forKey: Key.usesHiddenItemsBar)
        menuBarShowsOnHover = defaults.bool(forKey: Key.menuBarShowsOnHover)
        menuBarRehideStrategy = MenuBarRehideStrategy(
            rawValue: defaults.string(forKey: Key.menuBarRehideStrategy) ?? ""
        ) ?? .pointerLeaves
        menuBarRehideDelay = defaults.double(forKey: Key.menuBarRehideDelay)
        menuBarTintStyle = MenuBarTintStyle(
            rawValue: defaults.string(forKey: Key.menuBarTintStyle) ?? ""
        ) ?? .none
        menuBarTintColor = defaults.string(forKey: Key.menuBarTintColor) ?? "3478F6"
        menuBarTintOpacity = defaults.double(forKey: Key.menuBarTintOpacity)
        menuBarShowsBorder = defaults.bool(forKey: Key.menuBarShowsBorder)
        isChargeLimitEnabled = defaults.bool(forKey: Key.isChargeLimitEnabled)
        chargeLimitPercentage = defaults.integer(forKey: Key.chargeLimitPercentage)
        isDownloadManagerEnabled = defaults.bool(forKey: Key.isDownloadManagerEnabled)
        downloadFolderPath = defaults.string(forKey: Key.downloadFolderPath) ?? ""
        maximumConcurrentDownloads = defaults.integer(forKey: Key.maximumConcurrentDownloads)
        grabsLinksFromClipboard = defaults.bool(forKey: Key.grabsLinksFromClipboard)
        watchesBrowserTabs = defaults.bool(forKey: Key.watchesBrowserTabs)
        sortsDownloadsByKind = defaults.bool(forKey: Key.sortsDownloadsByKind)
        mediaToolPath = defaults.string(forKey: Key.mediaToolPath) ?? ""
        preferredMediaQuality = MediaQuality(
            rawValue: defaults.string(forKey: Key.preferredMediaQuality) ?? ""
        ) ?? .p1080
        mediaCookieSource = MediaCookieSource(
            rawValue: defaults.string(forKey: Key.mediaCookieSource) ?? ""
        ) ?? .none
        isBrowserBridgeEnabled = defaults.bool(forKey: Key.isBrowserBridgeEnabled)
        disabledModules = Set(defaults.stringArray(forKey: Key.disabledModules) ?? [])
        isCustomDockEnabled = defaults.bool(forKey: Key.isCustomDockEnabled)
        dockPins = defaults.stringArray(forKey: Key.dockPins) ?? []
        dockPinsSeeded = defaults.bool(forKey: Key.dockPinsSeeded)
        dockStyle = (defaults.data(forKey: Key.dockStyle)
            .flatMap { try? JSONDecoder().decode(DockStyle.self, from: $0) }) ?? DockStyle()

        if let data = defaults.data(forKey: Key.shortcuts),
           let stored = try? JSONDecoder().decode([String: HotKeyCombo].self, from: data) {
            shortcuts = stored
        } else {
            shortcuts = Preferences.defaultShortcuts
        }
    }

    // MARK: - Dock

    /// Whether the app draws a dock of its own in place of the system's.
    ///
    /// Off by default, and deliberately: it hides the real Dock to do its job, which is not
    /// something to start doing to somebody's Mac because they installed a menu bar app.
    var isCustomDockEnabled: Bool {
        didSet { defaults.set(isCustomDockEnabled, forKey: Key.isCustomDockEnabled) }
    }

    /// Which applications the app's own dock keeps, as bundle identifiers in the order they sit.
    ///
    /// Its own list rather than the system Dock's. It is seeded from the Dock once, so it opens
    /// looking exactly like what was there — but from then on it is ours, because a dock whose
    /// contents can only be changed by rearranging the dock it replaced is not a dock, it is a
    /// picture of one. Nothing here is ever written back to Apple's list.
    var dockPins: [String] {
        didSet { defaults.set(dockPins, forKey: Key.dockPins) }
    }

    /// Which hosted model the assistant thinks with. The key itself lives in the keychain, filed
    /// under this provider's name — see `KeychainStore`.
    var agentProvider: String {
        didSet { defaults.set(agentProvider, forKey: Key.agentProvider) }
    }

    /// The model identifier, or empty for the provider's default. Editable because model names age
    /// faster than releases of this app do.
    var agentModel: String {
        didSet { defaults.set(agentModel, forKey: Key.agentModel) }
    }

    /// Cloudflare addresses Workers AI per account, so its endpoint needs one.
    var agentCloudflareAccount: String {
        didSet { defaults.set(agentCloudflareAccount, forKey: Key.agentCloudflareAccount) }
    }

    /// Off until somebody sets a key. An assistant button that only ever says "no API key is set"
    /// is a button that should not be on the bar yet.
    var isAgentEnabled: Bool {
        didSet { defaults.set(isAgentEnabled, forKey: Key.isAgentEnabled) }
    }

    /// Whether the list above has been taken from the system Dock yet. Separate from the list being
    /// empty, which is a choice somebody may have made.
    var dockPinsSeeded: Bool {
        didSet { defaults.set(dockPinsSeeded, forKey: Key.dockPinsSeeded) }
    }

    /// How that dock looks. One JSON value rather than a dozen keys, so a preset is a single write
    /// and a field added later reads as its default out of what is already stored.
    var dockStyle: DockStyle {
        didSet {
            guard let data = try? JSONEncoder().encode(dockStyle) else { return }
            defaults.set(data, forKey: Key.dockStyle)
        }
    }

    // MARK: - Modules

    /// Which modules the user has switched off. Kept as a set of raw values rather than a key
    /// each, so a module added later is on by default without anything to register.
    private(set) var disabledModules: Set<String> {
        didSet { defaults.set(Array(disabledModules), forKey: Key.disabledModules) }
    }

    /// Whether a module is switched on.
    ///
    /// The five that shipped with a switch of their own still read it, so a choice made before
    /// modules existed is the one being honoured — there is no second copy of that truth to drift
    /// out of step.
    func isEnabled(_ module: AppModule) -> Bool {
        switch module {
        case .clipboard: isClipboardEnabled
        case .notch: isNotchPanelEnabled
        case .downloads: isDownloadManagerEnabled
        case .menuBar: isMenuBarManagerEnabled
        case .dockPreviews: isDockPreviewEnabled
        default: !disabledModules.contains(module.rawValue)
        }
    }

    func setEnabled(_ enabled: Bool, for module: AppModule) {
        switch module {
        case .clipboard: isClipboardEnabled = enabled
        case .notch: isNotchPanelEnabled = enabled
        case .downloads: isDownloadManagerEnabled = enabled
        case .menuBar: isMenuBarManagerEnabled = enabled
        case .dockPreviews: isDockPreviewEnabled = enabled
        default:
            if enabled {
                disabledModules.remove(module.rawValue)
            } else {
                disabledModules.insert(module.rawValue)
            }
        }
    }

    /// A shortcut is only worth registering when the part of the app it drives is switched on.
    func ownsShortcut(for action: HotKeyAction) -> Bool {
        guard let module = AppModule.owner(of: action) else { return true }
        return isEnabled(module)
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
    case temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "Icon only", comment: "Menu bar shows no metric")
        case .cpu: String(localized: "CPU load", comment: "Menu bar metric option")
        case .memory: String(localized: "Memory used", comment: "Menu bar metric option")
        case .temperature: String(localized: "CPU temperature", comment: "Menu bar metric option")
        }
    }

    /// The temperature comes from the SMC rather than the metrics samplers, so the status
    /// item has to keep a second service awake for it.
    var needsSensors: Bool { self == .temperature }
}
