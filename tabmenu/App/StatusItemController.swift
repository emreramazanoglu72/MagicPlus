//
//  StatusItemController.swift
//  tabmenu
//

import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item and its popover, and keeps the menu bar label in sync with metrics.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        configurePopover()
        observeMenuBarLabel()
    }

    // MARK: - Setup

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItemIcon()
        updateMenuBarLabel()
    }

    /// The icon becomes a cup while keep-awake holds its assertions, so a forgotten session is
    /// visible without opening anything.
    private func updateStatusItemIcon() {
        guard let button = statusItem.button else { return }
        let isAwake = environment.keepAwake.isActive
        button.image = NSImage(
            systemSymbolName: isAwake ? "cup.and.saucer.fill" : "square.grid.2x2",
            accessibilityDescription: isAwake ? "MagicPlus, keep awake on" : "MagicPlus"
        )
        button.toolTip = isAwake ? environment.keepAwake.statusText : nil
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: MenuBarRootView(environment: environment)
        )
        // Lets the popover follow the height of whichever tab is showing.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
    }

    // MARK: - Interaction

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        popover.isShown ? closePopover() : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        environment.frontmostTracker.remember()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        environment.updateMonitorMode(isPopoverOpen: true)
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let preferences = environment.preferences
        func on(_ module: AppModule) -> Bool { preferences.isEnabled(module) }

        func add(
            _ title: String,
            _ action: Selector,
            state: NSControl.StateValue = .off,
            key: String = ""
        ) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.state = state
        }

        /// A separator only between items that exist. A module switched off left its separator
        /// behind, and two rules in a row read as a menu that failed to load.
        func separate() {
            guard let last = menu.items.last, !last.isSeparatorItem else { return }
            menu.addItem(.separator())
        }

        add(String(localized: "Open MagicPlus", comment: "Status item menu"), #selector(openPanel))

        if on(.clipboard) {
            add(
                String(localized: "Clipboard History", comment: "Status item menu"),
                #selector(openClipboard)
            )
        }
        if on(.downloads) {
            add(
                String(localized: "Download Link on Clipboard", comment: "Status item menu"),
                #selector(downloadClipboardLink)
            )
        }
        if on(.textCapture) {
            add(
                String(localized: "Capture Text (OCR)", comment: "Status item menu"),
                #selector(captureText)
            )
        }
        if on(.quickNote) {
            add(String(localized: "Quick Note", comment: "Status item menu"), #selector(openQuickNote))
        }
        if on(.windows) {
            add(
                String(localized: "Rescue Windows", comment: "Status item menu"),
                #selector(rescueWindows)
            )
        }
        if on(.menuBar) {
            add(
                environment.menuBarManager.isRevealed(.hidden)
                    ? String(localized: "Hide Menu Bar Items", comment: "Status item menu")
                    : String(localized: "Show Menu Bar Items", comment: "Status item menu"),
                #selector(toggleHiddenItems)
            )
            add(
                String(localized: "Search Menu Bar Items…", comment: "Status item menu"),
                #selector(searchMenuBarItems)
            )
        }

        separate()

        if on(.presentation) {
            add(
                String(localized: "Presentation Mode", comment: "Status item menu"),
                #selector(togglePresentation),
                state: environment.presentation.isActive ? .on : .off
            )
        }
        if on(.keepAwake) {
            add(
                environment.keepAwake.isActive
                    ? environment.keepAwake.statusText
                    : String(localized: "Keep Awake", comment: "Status item menu"),
                #selector(toggleKeepAwake),
                state: environment.keepAwake.isActive ? .on : .off
            )
        }

        separate()

        add(String(localized: "About MagicPlus", comment: "Status item menu"), #selector(openAbout))
        add(String(localized: "Report an Issue…", comment: "Status item menu"), #selector(reportIssue))
        // Only worth offering while some switched-on module needs something granted.
        if !AppModule.permissionsNeeded(where: preferences.isEnabled).isEmpty {
            add(
                String(localized: "Permissions…", comment: "Status item menu"),
                #selector(openPermissions)
            )
        }
        if UpdaterService.isConfigured {
            add(
                String(localized: "Check for Updates…", comment: "Status item menu"),
                #selector(checkForUpdates)
            )
        }
        add(
            String(localized: "Settings…", comment: "Status item menu"),
            #selector(openSettings),
            key: ","
        )

        separate()
        add(String(localized: "Quit MagicPlus", comment: "Status item menu"), #selector(quit), key: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // The menu is detached again so the next left click reopens the popover.
        statusItem.menu = nil
    }

    @objc private func openPanel() { togglePopover() }
    @objc private func openClipboard() { environment.clipboardPanel.toggle() }
    @objc private func openSettings() { SettingsWindow.open() }
    @objc private func openPermissions() { environment.onboarding.show() }
    @objc private func openAbout() { AboutPanel.show() }
    @objc private func reportIssue() {
        IssueReport.compose(
            preferences: environment.preferences,
            accessibility: environment.permission,
            screenRecording: environment.screenRecordingPermission
        )
    }
    @objc private func checkForUpdates() { environment.updater.checkForUpdates() }
    @objc private func captureText() {
        Task { [environment] in
            guard let characters = await ScreenTextCapture.capture() else { return }
            environment.notchPanel.announce(.textCaptured(characters))
        }
    }
    @objc private func openQuickNote() { environment.quickNote.toggle() }
    @objc private func downloadClipboardLink() { environment.downloads.promptForClipboardLink() }
    @objc private func rescueWindows() {
        let rescued = WindowRescuer.rescueOffscreenWindows()
        environment.notchPanel.announce(.windowsRescued(rescued))
    }
    @objc private func toggleHiddenItems() { environment.menuBarManager.toggleHiddenItems() }
    @objc private func searchMenuBarItems() { environment.menuBarSearch.toggle() }
    @objc private func togglePresentation() { environment.presentation.toggle() }
    @objc private func toggleKeepAwake() { environment.keepAwake.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    func popoverDidClose(_ notification: Notification) {
        environment.updateMonitorMode(isPopoverOpen: false)
    }

    // MARK: - Menu bar label

    /// Observation tracking fires once per change, so the observer re-arms itself after each update.
    private func observeMenuBarLabel() {
        withObservationTracking {
            _ = environment.preferences.menuBarMetric
            _ = environment.monitor.snapshot
            _ = environment.hardware.sensors
            _ = environment.keepAwake.isActive
            _ = environment.keepAwake.remaining
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateStatusItemIcon()
                self?.updateMenuBarLabel()
                self?.observeMenuBarLabel()
            }
        }
    }

    private func updateMenuBarLabel() {
        guard let button = statusItem.button else { return }
        let snapshot = environment.monitor.snapshot

        switch environment.preferences.menuBarMetric {
        case .none:
            button.title = ""
        case .cpu:
            button.title = " \(Format.percent(snapshot.cpu.total))"
        case .memory:
            button.title = " \(Format.percent(snapshot.memory.pressure))"
        case .temperature:
            // Blank until the first sensor pass lands, rather than showing a made-up zero.
            if let celsius = environment.hardware.cpuTemperature {
                button.title = " \(Int(celsius.rounded()))°"
            } else {
                button.title = ""
            }
        }

        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        environment.updateMonitorMode(isPopoverOpen: popover.isShown)
    }
}

