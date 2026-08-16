//
//  WindowSwitcherPanelController.swift
//  tabmenu
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Presents the window switcher. Pressing and releasing the shortcut behaves like a classic
/// alt-tab; holding the modifier keeps the panel open so the list can be browsed or searched.
@MainActor
final class WindowSwitcherPanelController: NSObject, NSWindowDelegate {
    private let model: WindowSwitcherModel
    private let preferences: Preferences
    private let permission: AccessibilityPermission
    private let frontmostTracker: FrontmostApplicationTracker

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    /// Modifiers that were still held when the panel opened; releasing them commits the choice.
    private var holdModifiers: NSEvent.ModifierFlags?
    /// `orderOut` fires `windowDidResignKey` synchronously, which must not re-enter `hide()`.
    private var isHiding = false

    private var panelSize: CGSize {
        switch preferences.switcherLayout {
        case .grid: CGSize(width: 760, height: 520)
        case .list: CGSize(width: 520, height: 400)
        }
    }

    init(
        preferences: Preferences,
        frontmostTracker: FrontmostApplicationTracker,
        thumbnails: WindowThumbnailService,
        permission: AccessibilityPermission? = nil
    ) {
        self.preferences = preferences
        self.frontmostTracker = frontmostTracker
        self.permission = permission ?? .shared
        self.model = WindowSwitcherModel(thumbnails: thumbnails)
        super.init()

        model.onActivate = { [weak self] window in self?.activate(window) }
        model.onDismiss = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Entry point for the global shortcut: opens the switcher, or advances the selection
    /// when it is already open, so repeated presses cycle through windows.
    func handleShortcut() {
        if isVisible {
            model.moveSelection(by: 1)
        } else {
            show()
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard permission.isTrusted else {
            permission.request()
            return
        }

        frontmostTracker.remember()
        holdModifiers = currentlyHeldShortcutModifiers()
        model.reload(preselectingPrevious: holdModifiers != nil)

        // Rebuilt each time so a layout change in Settings takes effect immediately.
        panel?.orderOut(nil)
        let panel = makePanel()
        self.panel = panel
        FloatingPanel.center(panel, size: panelSize)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startMonitors()
    }

    /// - Parameter restoringPreviousApplication: `false` when a window is about to be
    ///   focused, so the outgoing app is not raised on top of it.
    func hide(restoringPreviousApplication: Bool = true) {
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }

        stopMonitors()
        holdModifiers = nil
        panel?.orderOut(nil)
        if restoringPreviousApplication { frontmostTracker.restore() }
    }

    private func activate(_ window: SwitchableWindow) {
        hide(restoringPreviousApplication: false)
        WindowLister.focus(window)
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel.make(
            size: panelSize,
            title: String(localized: "Switch Windows", comment: "Floating panel title"),
            content: WindowSwitcherPanelView(
                model: model,
                layout: preferences.switcherLayout,
                showsThumbnails: preferences.showsWindowThumbnails
            )
        )
        panel.delegate = self
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        // The user clicked elsewhere; raising the previous app would steal that focus.
        hide(restoringPreviousApplication: false)
    }

    // MARK: - Keyboard

    /// Returns the shortcut's modifiers if they are still down, meaning the user is holding
    /// the combination rather than having tapped it.
    private func currentlyHeldShortcutModifiers() -> NSEvent.ModifierFlags? {
        guard let combo = preferences.shortcut(for: .switchWindows) else { return nil }
        let required = combo.modifiers.intersection([.command, .option, .control, .shift])
        guard !required.isEmpty else { return nil }
        return NSEvent.modifierFlags.intersection(required) == required ? required : nil
    }

    private func startMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, self.isVisible else { return event }
                return self.handle(event) ? nil : event
            }
        }
        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                self?.handleFlagsChanged(event)
                return event
            }
        }
    }

    private func stopMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isVisible, let holdModifiers else { return }
        guard event.modifierFlags.intersection(holdModifiers) != holdModifiers else { return }
        model.activateSelection()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let hasCommand = event.modifierFlags.contains(.command)

        switch Int(event.keyCode) {
        case kVK_ANSI_W where hasCommand:
            model.closeSelection()
            return true
        case kVK_ANSI_M where hasCommand:
            model.minimizeSelection()
            return true
        case kVK_ANSI_Q where hasCommand:
            model.quitSelectedApplication()
            return true
        case kVK_Escape:
            model.dismiss()
            return true
        case kVK_Tab:
            model.moveSelection(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case kVK_UpArrow:
            model.moveSelection(by: -1)
            return true
        case kVK_DownArrow:
            model.moveSelection(by: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.activateSelection()
            return true
        default:
            return false
        }
    }
}
