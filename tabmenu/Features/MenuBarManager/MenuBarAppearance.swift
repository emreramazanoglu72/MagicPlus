//
//  MenuBarAppearance.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// How the menu bar is tinted, if at all.
enum MenuBarTintStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case solid
    case gradient

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None", comment: "Menu bar tint style")
        case .solid: String(localized: "Solid colour", comment: "Menu bar tint style")
        case .gradient: String(localized: "Gradient", comment: "Menu bar tint style")
        }
    }
}

/// Paints over the menu bar.
///
/// One window per display, sitting at the menu bar's own level: status items live a level
/// above it, so their icons and the menus stay legible on top of the tint. The window never
/// takes a click, and gets out of the way in full screen where there is no bar to tint.
@MainActor
final class MenuBarAppearanceOverlay {
    private let preferences: Preferences
    private var windows: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start() {
        observe()
        update()
    }

    /// Rebuilds the overlay from the current preferences and display arrangement.
    func update() {
        tearDown()
        guard preferences.menuBarTintStyle != .none else { return }

        let color = Color(hex: preferences.menuBarTintColor, fallback: .blue)
        for screen in NSScreen.screens where MenuBarGeometry.isMenuBarVisible(on: screen) {
            windows.append(makeWindow(for: screen, color: color))
        }
    }

    private func makeWindow(for screen: NSScreen, color: Color) -> NSWindow {
        let frame = MenuBarGeometry.menuBarFrame(for: screen)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = NSHostingView(
            rootView: MenuBarTintView(
                style: preferences.menuBarTintStyle,
                color: color,
                opacity: preferences.menuBarTintOpacity,
                showsBorder: preferences.menuBarShowsBorder
            )
        )
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        return window
    }

    private func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// Displays come and go, and so does the bar itself: entering full screen takes it away
    /// entirely, which is exactly when a stale overlay would be left floating over an app.
    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
    }
}

struct MenuBarTintView: View {
    let style: MenuBarTintStyle
    let color: Color
    let opacity: Double
    let showsBorder: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            fill
            if showsBorder {
                Rectangle()
                    .fill(color.opacity(min(1, opacity + 0.4)))
                    .frame(height: 1)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var fill: some View {
        switch style {
        case .none:
            Color.clear
        case .solid:
            color.opacity(opacity)
        case .gradient:
            LinearGradient(
                colors: [color.opacity(opacity), color.opacity(opacity * 0.15)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}
