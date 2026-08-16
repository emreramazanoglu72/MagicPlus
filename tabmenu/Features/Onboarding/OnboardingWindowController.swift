//
//  OnboardingWindowController.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// Owns the welcome window. Shown once on first launch, and on demand from Settings.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let catalog: PermissionCatalog
    private let preferences: Preferences
    private var window: NSWindow?

    init(catalog: PermissionCatalog, preferences: Preferences) {
        self.catalog = catalog
        self.preferences = preferences
        super.init()
    }

    func showIfFirstLaunch() {
        guard !preferences.hasCompletedOnboarding else { return }
        show()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to MagicPlus", comment: "Onboarding window title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: OnboardingView(catalog: catalog) { [weak self] in self?.finish() }
        )
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        preferences.hasCompletedOnboarding = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing counts as finishing: the window is reachable again from Settings.
        preferences.hasCompletedOnboarding = true
        catalog.stopPolling()
        window = nil
    }
}
