//
//  ModuleTests.swift
//  tabmenuTests
//

import Testing
import Foundation
@testable import tabmenu

@MainActor
@Suite("Modules")
struct ModuleTests {
    private func makePreferences() -> Preferences {
        let defaults = UserDefaults(suiteName: "module.tests") ?? .standard
        defaults.removePersistentDomain(forName: "module.tests")
        return Preferences(defaults: defaults)
    }

    /// Every module has to be describable, or the settings list is a column of switches with
    /// nothing to go on.
    @Test func everyModuleSaysWhatItIs() {
        for module in AppModule.allCases {
            #expect(!module.title.isEmpty, "\(module.rawValue) has no name")
            #expect(!module.summary.isEmpty, "\(module.rawValue) says nothing about itself")
            #expect(!module.symbolName.isEmpty, "\(module.rawValue) has no glyph")
            // A summary that is only a restatement of the name is not a summary.
            #expect(module.summary.count > module.title.count)
        }

        let keys = AppModule.allCases.map(\.preferenceKey)
        #expect(Set(keys).count == keys.count, "two modules share a preference key")
    }

    /// Everything is on until someone says otherwise: a module added in a later version must not
    /// arrive switched off.
    @Test func everythingIsOnToBeginWith() {
        let preferences = makePreferences()
        for module in AppModule.allCases {
            #expect(preferences.isEnabled(module), "\(module.rawValue) starts off")
        }
    }

    /// The five that shipped with a switch of their own still read it. There is no second copy of
    /// that truth to drift out of step — a choice made before modules existed is still honoured.
    @Test func theOldSwitchesAreStillTheSameSwitch() {
        let preferences = makePreferences()

        preferences.isClipboardEnabled = false
        #expect(!preferences.isEnabled(.clipboard))
        preferences.setEnabled(true, for: .clipboard)
        #expect(preferences.isClipboardEnabled)

        preferences.isNotchPanelEnabled = false
        #expect(!preferences.isEnabled(.notch))
        preferences.isDownloadManagerEnabled = false
        #expect(!preferences.isEnabled(.downloads))
        preferences.isMenuBarManagerEnabled = false
        #expect(!preferences.isEnabled(.menuBar))
        preferences.isDockPreviewEnabled = false
        #expect(!preferences.isEnabled(.dockPreviews))
    }

    @Test func switchingOneOffAndOnAgainSticks() {
        let preferences = makePreferences()
        for module in AppModule.allCases {
            preferences.setEnabled(false, for: module)
            #expect(!preferences.isEnabled(module), "\(module.rawValue) would not switch off")
            preferences.setEnabled(true, for: module)
            #expect(preferences.isEnabled(module), "\(module.rawValue) would not switch back on")
        }
    }

    /// The part that makes the switch mean something: a module that is off must not hold a
    /// system-wide key on behalf of something the user has turned off.
    @Test func aModuleThatIsOffHoldsNoShortcuts() {
        let preferences = makePreferences()
        let owned: [(AppModule, HotKeyAction)] = [
            (.windows, .window(.left)),
            (.windows, .layout(1)),
            (.windows, .rescueWindows),
            (.windowSwitcher, .switchWindows),
            (.clipboard, .showClipboard),
            (.menuSearch, .searchMenus),
            (.quickNote, .quickNote),
            (.textCapture, .captureText),
            (.microphone, .toggleMicMute),
            (.keepAwake, .toggleKeepAwake),
            (.presentation, .togglePresentation),
            (.menuBar, .toggleHiddenItems),
            (.menuBar, .searchMenuBarItems)
        ]

        for (module, action) in owned {
            #expect(AppModule.owner(of: action) == module, "\(action.id) is owned by the wrong module")
            preferences.setEnabled(false, for: module)
            #expect(!preferences.ownsShortcut(for: action), "\(action.id) survived its module")
            preferences.setEnabled(true, for: module)
            #expect(preferences.ownsShortcut(for: action))
        }
    }

    /// Opening the app's own popover is not a feature that can be switched off, so it belongs to
    /// no module and is always registered.
    @Test func theAppsOwnShortcutBelongsToNoModule() {
        let preferences = makePreferences()
        #expect(AppModule.owner(of: .togglePanel) == nil)
        for module in AppModule.allCases { preferences.setEnabled(false, for: module) }
        #expect(preferences.ownsShortcut(for: .togglePanel))
    }

    /// Every shortcut is accounted for: one that belongs to a module nobody mapped would keep its
    /// key registered forever, which is the failure this whole arrangement exists to prevent.
    @Test func everyShortcutIsAccountedFor() {
        for action in HotKeyAction.allCases {
            let owner = AppModule.owner(of: action)
            #expect(owner != nil || action.id == "panel.toggle", "\(action.id) belongs to nothing")
        }
    }

    /// A tab for something that is not running is a tab with nothing behind it.
    @Test func tabsFollowTheirModules() {
        #expect(MenuBarTab.windows.module == .windows)
        #expect(MenuBarTab.clipboard.module == .clipboard)
        #expect(MenuBarTab.downloads.module == .downloads)
        #expect(MenuBarTab.menuBar.module == .menuBar)
        #expect(MenuBarTab.stats.module == .systemMonitor)

        #expect(NotchTab.downloads.module == .downloads)
        // The rest are parts of the island itself and go wherever it goes.
        for tab in [NotchTab.media, .mixer, .agenda, .shelf, .mirror] {
            #expect(tab.module == nil, "\(tab.rawValue) should not be switchable on its own")
        }
    }
}

@MainActor
@Suite("Module permissions")
struct ModulePermissionTests {
    /// The mirror of the shortcut test: a permission no module claims is a permission the app asks
    /// for and cannot say what it does with — the single fastest way to lose a user's trust.
    @Test func everyPermissionIsNeededBySomeModule() {
        let claimed = Set(AppModule.allCases.flatMap(\.requiredPermissions))
        for kind in PermissionKind.allCases {
            #expect(claimed.contains(kind), "\(kind.rawValue) is requested on behalf of nothing")
        }
    }

    @Test func everythingOnAsksForEverything() {
        let needed = AppModule.permissionsNeeded { _ in true }
        // Also fixes the order: the list follows the catalog, so the rows do not shuffle when a
        // module is switched off.
        #expect(needed == PermissionKind.allCases)
    }

    @Test func everythingOffAsksForNothing() {
        #expect(AppModule.permissionsNeeded { _ in false }.isEmpty)
    }

    /// The list is a union over what is on, not a lookup per module: Automation survives the notch
    /// being switched off because downloads still needs it.
    @Test func switchingOffOneModuleOnlyDropsWhatNothingElseNeeds() {
        let needed = AppModule.permissionsNeeded { $0 != .notch }
        #expect(!needed.contains(.camera))
        #expect(!needed.contains(.calendar))
        #expect(needed.contains(.automation))

        let withoutBoth = AppModule.permissionsNeeded { $0 != .notch && $0 != .downloads }
        #expect(!withoutBoth.contains(.automation))
    }

    /// Named so that adding a permission to one of these is a deliberate act with a failing test
    /// to explain it.
    @Test func someModulesNeedNothingGranted() {
        for module in [AppModule.quickNote, .microphone, .keepAwake, .presentation, .systemMonitor, .hardware] {
            #expect(module.requiredPermissions.isEmpty, "\(module.rawValue) now wants a permission")
        }
    }

    /// Accessibility is what a fresh install is actually asked for, and it must survive the app
    /// being pared back to its smallest useful shape.
    @Test func windowManagementAloneStillNeedsAccessibility() {
        #expect(AppModule.permissionsNeeded { $0 == .windows } == [.accessibility])
    }
}

/// What the built bundle claims about itself. These read `Bundle.main`, which under a test host is
/// the app — so a release setting that regressed fails here rather than after upload.
@Suite("Shipping configuration")
struct ShippingConfigurationTests {
    private func string(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }

    /// Without an EdDSA public key Sparkle falls back to Apple code-signing checks alone, which
    /// accept any same-team build served by whoever controls the feed host.
    @Test func updatesAreVerifiable() {
        #expect(!string("SUPublicEDKey").isEmpty)
        #expect(UpdaterService.isConfigured)
    }

    @Test func theFeedIsHTTPSAndReal() {
        let feed = string("SUFeedURL")
        let url = URL(string: feed)
        #expect(url?.scheme == "https", "update feed must not be plaintext: \(feed)")
        #expect(url?.host?.contains(".") == true)
        #expect(feed.hasSuffix(".xml"))
    }

    @Test func checksHappenWithoutBeingAsked() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == true)
    }

    /// An app that cannot say which version it is running cannot have its bug reports answered,
    /// and the About panel reads both of these straight from here.
    @Test func theBundleCanIdentifyItself() {
        let marketing = string("CFBundleShortVersionString")
        let build = string("CFBundleVersion")
        #expect(marketing.split(separator: ".").count >= 2, "not a version: \(marketing)")
        #expect(Int(build) != nil, "build number must be an integer for Sparkle to order it: \(build)")
        #expect(!string("NSHumanReadableCopyright").isEmpty)
    }
}
