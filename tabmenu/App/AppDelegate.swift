//
//  AppDelegate.swift
//  tabmenu
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let environment = AppEnvironment.shared
        let controller = StatusItemController(environment: environment)
        statusItemController = controller
        environment.onTogglePanel = { [weak controller] in controller?.togglePopover() }
        environment.start()

        // SwiftUI builds the main menu after launch finishes, so the redirect waits a turn.
        DispatchQueue.main.async { self.redirectSettingsMenuItem() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.clipboard.stop()
        AppEnvironment.shared.monitor.stop()
        AppEnvironment.shared.keepAwake.deactivate()
        AppEnvironment.shared.audioMixer.stopAll()
        // Nothing this app does to the hardware may outlive it: charging goes back to normal
        // before the process is gone, and the helper's watchdog covers the crash case.
        AppEnvironment.shared.chargeLimit.shutDown()
        HotKeyManager.shared.unregisterAll()
    }

    /// Keeps the app alive when the settings window is closed; it lives in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Points ⌘, at the settings window this app actually owns, rather than SwiftUI's empty
    /// `Settings` scene.
    private func redirectSettingsMenuItem() {
        guard let applicationMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        let settingsSelector = Selector(("showSettingsWindow:"))

        for item in applicationMenu.items where item.action == settingsSelector {
            item.target = self
            item.action = #selector(openSettings)
        }
    }

    @objc private func openSettings() {
        SettingsWindow.open()
    }
}
