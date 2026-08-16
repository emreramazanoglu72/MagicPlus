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
        menu.addItem(
            withTitle: String(localized: "Open MagicPlus", comment: "Status item menu"),
            action: #selector(openPanel),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: String(localized: "Clipboard History", comment: "Status item menu"),
            action: #selector(openClipboard),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: String(localized: "Capture Text (OCR)", comment: "Status item menu"),
            action: #selector(captureText),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: String(localized: "Quick Note", comment: "Status item menu"),
            action: #selector(openQuickNote),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: String(localized: "Rescue Windows", comment: "Status item menu"),
            action: #selector(rescueWindows),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())

        let presentationItem = menu.addItem(
            withTitle: String(localized: "Presentation Mode", comment: "Status item menu"),
            action: #selector(togglePresentation),
            keyEquivalent: ""
        )
        presentationItem.target = self
        presentationItem.state = environment.presentation.isActive ? .on : .off

        let keepAwakeItem = menu.addItem(
            withTitle: environment.keepAwake.isActive
                ? environment.keepAwake.statusText
                : String(localized: "Keep Awake", comment: "Status item menu"),
            action: #selector(toggleKeepAwake),
            keyEquivalent: ""
        )
        keepAwakeItem.target = self
        keepAwakeItem.state = environment.keepAwake.isActive ? .on : .off
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Permissions…", comment: "Status item menu"),
            action: #selector(openPermissions),
            keyEquivalent: ""
        ).target = self
        if UpdaterService.isConfigured {
            menu.addItem(
                withTitle: String(localized: "Check for Updates…", comment: "Status item menu"),
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            ).target = self
        }
        menu.addItem(
            withTitle: String(localized: "Settings…", comment: "Status item menu"),
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Quit MagicPlus", comment: "Status item menu"),
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // The menu is detached again so the next left click reopens the popover.
        statusItem.menu = nil
    }

    @objc private func openPanel() { togglePopover() }
    @objc private func openClipboard() { environment.clipboardPanel.toggle() }
    @objc private func openSettings() { SettingsWindow.open() }
    @objc private func openPermissions() { environment.onboarding.show() }
    @objc private func checkForUpdates() { environment.updater.checkForUpdates() }
    @objc private func captureText() {
        Task { [environment] in
            guard let characters = await ScreenTextCapture.capture() else { return }
            environment.notchPanel.announce(.textCaptured(characters))
        }
    }
    @objc private func openQuickNote() { environment.quickNote.toggle() }
    @objc private func rescueWindows() {
        let rescued = WindowRescuer.rescueOffscreenWindows()
        environment.notchPanel.announce(.windowsRescued(rescued))
    }
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
        }

        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        environment.updateMonitorMode(isPopoverOpen: popover.isShown)
    }
}

