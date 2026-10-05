//
//  DockTweakService.swift
//  MagicPlus
//

import AppKit
import Observation
import os

/// Apple's own Dock settings that System Settings never shows.
///
/// The Dock reads a dozen preferences that have no interface: how long it waits before sliding out,
/// whether an icon bounces for attention, whether clicking one app hides the others. They are not
/// tricks and nothing is patched — each is a key `Dock.app` already looks for, and this writes it
/// the way `defaults` would and then asks the Dock to read it again.
///
/// Two decisions worth knowing about:
///
/// **The Dock's own domain is the only copy of the truth.** Nothing here is mirrored into the app's
/// preferences, so a value changed in Terminal, by another app, or by macOS itself is the value this
/// shows. A second copy would eventually disagree with the Dock, and the Dock would win.
///
/// **Off means "as macOS had it", not "our other value".** Switching a tweak off removes the key
/// rather than writing a false-ish value, so the Dock falls back to its own default — which is also
/// what makes restoring everything a matter of removing what we added. Settings that System Settings
/// does expose are deliberately not offered here: undoing a choice the user made in Apple's own
/// interface is not this app's business.
@Observable
@MainActor
final class DockTweakService {
    /// One hidden Dock setting: the key the Dock reads, and the value that turns it on.
    enum Tweak: String, CaseIterable, Identifiable, Sendable {
        case instantReveal
        case fasterAnimation
        case runningAppsOnly
        case noAttentionBounce
        case noLaunchBounce
        case dimHiddenApps
        case singleAppMode
        case scrollToShowWindows
        case groupWindowsByApp

        var id: String { rawValue }

        var key: String {
            switch self {
            case .instantReveal: "autohide-delay"
            case .fasterAnimation: "autohide-time-modifier"
            case .runningAppsOnly: "static-only"
            case .noAttentionBounce: "no-bouncing"
            case .noLaunchBounce: "launchanim"
            case .dimHiddenApps: "showhidden"
            case .singleAppMode: "single-app"
            case .scrollToShowWindows: "scroll-to-open"
            case .groupWindowsByApp: "expose-group-apps"
            }
        }

        /// What gets written when the switch goes on. Removing the key is what "off" means.
        var enabledValue: NSNumber {
            switch self {
            case .instantReveal: NSNumber(value: 0.0)
            // Not zero: the Dock still animates, just quickly. Nothing at all reads as a glitch.
            case .fasterAnimation: NSNumber(value: 0.4)
            case .noLaunchBounce: NSNumber(value: false)
            default: NSNumber(value: true)
            }
        }

        var title: String {
            switch self {
            case .instantReveal:
                String(localized: "Appear instantly", comment: "Dock tweak")
            case .fasterAnimation:
                String(localized: "Faster hide and show", comment: "Dock tweak")
            case .runningAppsOnly:
                String(localized: "Only running apps", comment: "Dock tweak")
            case .noAttentionBounce:
                String(localized: "No bouncing for attention", comment: "Dock tweak")
            case .noLaunchBounce:
                String(localized: "No bounce while an app opens", comment: "Dock tweak")
            case .dimHiddenApps:
                String(localized: "Dim hidden apps", comment: "Dock tweak")
            case .singleAppMode:
                String(localized: "Clicking an app hides the others", comment: "Dock tweak")
            case .scrollToShowWindows:
                String(localized: "Scroll up on an icon for its windows", comment: "Dock tweak")
            case .groupWindowsByApp:
                String(localized: "Group windows by app in Mission Control", comment: "Dock tweak")
            }
        }

        var summary: String {
            switch self {
            case .instantReveal:
                String(localized: "A hidden Dock waits half a second before sliding out. This removes the wait.", comment: "Dock tweak summary")
            case .fasterAnimation:
                String(localized: "Shortens the slide itself, without removing it.", comment: "Dock tweak summary")
            case .runningAppsOnly:
                String(localized: "Hides everything that is not open, turning the Dock into a list of what is running.", comment: "Dock tweak summary")
            case .noAttentionBounce:
                String(localized: "An app wanting attention stays still and lights its indicator instead.", comment: "Dock tweak summary")
            case .noLaunchBounce:
                String(localized: "Icons stop hopping while their app starts up.", comment: "Dock tweak summary")
            case .dimHiddenApps:
                String(localized: "Apps you have hidden with ⌘H show through at half strength, so you can tell.", comment: "Dock tweak summary")
            case .singleAppMode:
                String(localized: "One app at a time: clicking its icon hides every other window.", comment: "Dock tweak summary")
            case .scrollToShowWindows:
                String(localized: "A scroll up over an icon opens that app's windows, without a click.", comment: "Dock tweak summary")
            case .groupWindowsByApp:
                String(localized: "Mission Control stacks each app's windows together instead of spreading them.", comment: "Dock tweak summary")
            }
        }
    }

    /// The minimise animation. Apple's interface offers two of the three the Dock can draw.
    enum MinimizeEffect: String, CaseIterable, Identifiable, Sendable {
        case genie
        case scale
        case suck

        var id: String { rawValue }

        var title: String {
            switch self {
            case .genie: String(localized: "Genie", comment: "Dock minimize effect")
            case .scale: String(localized: "Scale", comment: "Dock minimize effect")
            case .suck: String(localized: "Suck", comment: "Dock minimize effect, hidden in System Settings")
            }
        }
    }

    private static let minimizeEffectKey = "mineffect"

    /// The preferences domain to write. Overridden by tests, which must never restart the Dock a
    /// person is using or rearrange the icons they arranged.
    @ObservationIgnored private let domain: CFString
    @ObservationIgnored private let restart: @MainActor () -> Void

    init(
        domain: String = "com.apple.dock",
        restart: (@MainActor () -> Void)? = nil
    ) {
        self.domain = domain as CFString
        self.restart = restart ?? {
            // Terminating it is enough: launchd keeps the Dock alive and brings it straight back
            // with the new settings, which is exactly what `killall Dock` does.
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
                application.terminate()
            }
        }
    }

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Dock")
    /// Bumped after every write so the views re-read the Dock's domain rather than a copy.
    private var revision = 0
    @ObservationIgnored private var restartTask: Task<Void, Never>?

    // MARK: - Reading

    func isOn(_ tweak: Tweak) -> Bool {
        _ = revision
        return value(for: tweak.key) != nil
    }

    var minimizeEffect: MinimizeEffect {
        _ = revision
        let raw = value(for: Self.minimizeEffectKey) as? String
        return MinimizeEffect(rawValue: raw ?? "") ?? .genie
    }

    /// Whether anything here has been changed from what macOS ships with.
    var hasChanges: Bool {
        _ = revision
        return Tweak.allCases.contains { isOn($0) } || value(for: Self.minimizeEffectKey) != nil
    }

    private func value(for key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    // MARK: - Writing

    func set(_ tweak: Tweak, on: Bool) {
        write(tweak.key, value: on ? tweak.enabledValue : nil)
    }

    func setMinimizeEffect(_ effect: MinimizeEffect) {
        // Genie is the Dock's own default, so choosing it removes the key rather than pinning it.
        write(Self.minimizeEffectKey, value: effect == .genie ? nil : effect.rawValue as NSString)
    }

    /// Puts every one of these settings back to what macOS ships with, and nothing else: keys this
    /// never wrote are left exactly as they are.
    func restoreDefaults() {
        for tweak in Tweak.allCases {
            CFPreferencesSetAppValue(tweak.key as CFString, nil, domain)
        }
        CFPreferencesSetAppValue(Self.minimizeEffectKey as CFString, nil, domain)
        CFPreferencesAppSynchronize(domain)
        revision += 1
        scheduleRestart()
    }

    private func write(_ key: String, value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, domain)
        CFPreferencesAppSynchronize(domain)
        revision += 1
        logger.notice("dock \(key, privacy: .public) \(value == nil ? "cleared" : "set", privacy: .public)")
        scheduleRestart()
    }

    // MARK: - Separators

    /// The Dock's own blank tile, which has no interface anywhere.
    ///
    /// `Dock.app` has always understood a tile of type `spacer-tile` and drawn it as a gap, which is
    /// how every "add a separator to the Dock" recipe works. The list of icons is the user's, so
    /// this only ever appends one entry or filters ones of exactly this type out again — it never
    /// rebuilds the list, because a mistake there would scramble a Dock somebody arranged by hand.
    private static let appsKey = "persistent-apps"
    private static let spacerTypes = ["spacer-tile", "small-spacer-tile", "flex-spacer-tile"]

    var separatorCount: Int {
        _ = revision
        return persistentApps().count { app in
            Self.spacerTypes.contains(app["tile-type"] as? String ?? "")
        }
    }

    func addSeparator() {
        guard let apps = readableApps() else { return }
        writePersistentApps(apps + [["tile-type": "spacer-tile"]])
    }

    func removeSeparators() {
        guard let apps = readableApps() else { return }
        writePersistentApps(apps.filter { app in
            !Self.spacerTypes.contains(app["tile-type"] as? String ?? "")
        })
    }

    /// The Dock's arrangement, or `nil` when it could not be read.
    ///
    /// The distinction is the whole point. `persistentApps()` answers an unreadable domain with an
    /// empty array, and writing that back — which is what adding or removing a separator does —
    /// replaces somebody's Dock with nothing. A failed read and a Dock with no icons in it look
    /// identical from here, so the safe reading is the one that refuses to write.
    ///
    /// This is not hypothetical. It emptied a Dock during development.
    private func readableApps() -> [[String: Any]]? {
        let apps = persistentApps()
        guard !apps.isEmpty else {
            logger.error("the Dock listed no applications; refusing to write its arrangement")
            return nil
        }
        return apps
    }

    private func persistentApps() -> [[String: Any]] {
        value(for: Self.appsKey) as? [[String: Any]] ?? []
    }

    private func writePersistentApps(_ apps: [[String: Any]]) {
        CFPreferencesSetAppValue(Self.appsKey as CFString, apps as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        revision += 1
        logger.notice("dock now has \(self.separatorCount, privacy: .public) separators")
        scheduleRestart()
    }

    // MARK: - Making it take effect

    /// The Dock only reads these when it starts, so it is asked to start again.
    ///
    /// Debounced, because a settings pane produces a burst of changes as someone works through it
    /// and restarting the Dock nine times in four seconds is a visible mess.
    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.restartDock()
        }
    }

    func restartDock() {
        restart()
        logger.notice("dock restarted")
    }

    // MARK: - Module lifecycle

    /// Switching the module off returns the Dock to how macOS had it.
    ///
    /// These are system settings rather than something this app holds open, so leaving them behind
    /// would mean a module that is off is still changing the Mac — which is the one thing the
    /// module switch promises it will not do.
    func moduleDidChange(isEnabled: Bool) {
        guard !isEnabled, hasChanges else { return }
        logger.notice("dock module switched off, restoring defaults")
        restoreDefaults()
    }
}
