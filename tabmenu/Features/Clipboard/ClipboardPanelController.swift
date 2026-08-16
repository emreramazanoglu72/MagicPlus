//
//  ClipboardPanelController.swift
//  tabmenu
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the floating clipboard window, its key handling, and the hand-off back to the
/// application the user was working in.
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private let model: ClipboardPanelModel
    private let service: ClipboardService
    private let preferences: Preferences
    private let frontmostTracker: FrontmostApplicationTracker

    private var panel: NSPanel?
    private var keyMonitor: Any?
    /// `orderOut` fires `windowDidResignKey` synchronously, which must not re-enter `hide()`.
    private var isHiding = false

    private static let panelSize = CGSize(width: 660, height: 440)
    /// Gives the restored application time to become key before the paste event is posted.
    private static let pasteDelay: TimeInterval = 0.12

    init(
        service: ClipboardService,
        preferences: Preferences,
        frontmostTracker: FrontmostApplicationTracker
    ) {
        self.service = service
        self.preferences = preferences
        self.frontmostTracker = frontmostTracker
        self.model = ClipboardPanelModel(service: service)
        super.init()

        model.onActivate = { [weak self] item in self?.activate(item) }
        model.onActivateTransformed = { [weak self] _ in self?.pasteWhatIsAlreadyOnThePasteboard() }
        model.onDismiss = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Presentation

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        frontmostTracker.remember()
        model.reset()

        let panel = panel ?? makePanel()
        self.panel = panel
        FloatingPanel.center(panel, size: Self.panelSize)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyMonitor()
    }

    /// - Parameter restoringPreviousApplication: `false` when the user already focused
    ///   another app themselves, so it is not raised over their choice.
    func hide(restoringPreviousApplication: Bool = true) {
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }

        stopKeyMonitor()
        panel?.orderOut(nil)
        if restoringPreviousApplication { frontmostTracker.restore() }
    }

    private func activate(_ item: ClipboardItem) {
        service.copyToPasteboard(item)
        pasteWhatIsAlreadyOnThePasteboard()
    }

    private func pasteWhatIsAlreadyOnThePasteboard() {
        hide()

        guard preferences.pastesAutomatically else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteDelay) {
            KeyboardSimulator.sendPaste()
        }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel.make(
            size: Self.panelSize,
            title: String(localized: "Clipboard History", comment: "Floating panel title"),
            content: ClipboardPanelView(model: model)
        )
        panel.delegate = self
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        // The user clicked elsewhere; raising the previous app would steal that focus.
        hide(restoringPreviousApplication: false)
    }

    // MARK: - Keyboard

    /// The search field keeps focus, so navigation keys are intercepted before they reach it.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let hasCommand = event.modifierFlags.contains(.command)

        switch Int(event.keyCode) {
        case kVK_Escape:
            model.dismiss()
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
        case kVK_Delete where hasCommand:
            model.deleteSelection()
            return true
        case kVK_ANSI_P where hasCommand:
            model.togglePinSelection()
            return true
        default:
            return false
        }
    }
}
