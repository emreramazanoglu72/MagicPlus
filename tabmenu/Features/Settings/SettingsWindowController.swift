//
//  SettingsWindowController.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// Owns the settings window directly instead of relying on SwiftUI's `Settings` scene.
///
/// `showSettingsWindow:` never reaches a target from a menu bar popover in an accessory app,
/// so the window is created and presented here where its lifetime is explicit.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // The style mask is set at construction: changing it afterwards on a window that
        // hosts SwiftUI throws during the next constraint pass.
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: SettingsView.windowSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "MagicPlus Settings", comment: "Settings window title")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(environment: .shared))
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

enum SettingsWindow {
    static func open() {
        SettingsWindowController.shared.show()
    }
}
