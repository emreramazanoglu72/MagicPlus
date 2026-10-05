//
//  DockTileMenu.swift
//  MagicPlus
//

import AppKit
import SwiftUI

/// What macOS puts behind a right-click on a Dock icon, rebuilt.
///
/// The order and the wording are Apple's on purpose: someone right-clicking a dock icon already
/// knows what they expect to find, and a menu that puts the same things in different places is a
/// menu they have to read. Open windows first with a mark against the one in front, then New
/// Window, then Options — Keep in Dock, Open at Login, Show in Finder — then Show All Windows,
/// Hide, and Quit.
///
/// Two of these cannot be done the way the Dock does them. "Open at Login" has no public API for
/// somebody else's application, so it goes through System Events. "Show All Windows" is Exposé,
/// which nothing public triggers for one app, so it brings that app's windows forward instead —
/// which is what the name promises and most of what it is used for.
struct DockTileMenu: View {
    let tile: DockTile
    let windows: [SwitchableWindow]
    let isPinned: Bool
    let opensAtLogin: Bool

    var onOpen: () -> Void
    var onFocusWindow: (SwitchableWindow) -> Void
    var onNewWindow: () -> Void
    var onTogglePinned: () -> Void
    var onToggleOpenAtLogin: () -> Void
    var onReveal: () -> Void
    var onShowAllWindows: () -> Void
    var onHide: () -> Void
    var onQuit: () -> Void
    var onForceQuit: () -> Void

    /// A menu with nothing behind it, for the moment between a view asking and a controller
    /// existing. Never seen in practice; better than an implicitly unwrapped controller.
    static func empty(for tile: DockTile) -> DockTileMenu {
        DockTileMenu(
            tile: tile, windows: [], isPinned: false, opensAtLogin: false,
            onOpen: {}, onFocusWindow: { _ in }, onNewWindow: {}, onTogglePinned: {},
            onToggleOpenAtLogin: {}, onReveal: {}, onShowAllWindows: {}, onHide: {},
            onQuit: {}, onForceQuit: {}
        )
    }

    var body: some View {
        if !windows.isEmpty {
            ForEach(windows) { window in
                Button {
                    onFocusWindow(window)
                } label: {
                    // The mark against the window in front, as the Dock does it.
                    Label(
                        window.title.isEmpty ? tile.name : window.title,
                        systemImage: window.isMinimized ? "arrow.down.right.and.arrow.up.left" : "checkmark"
                    )
                }
            }
            Divider()
        }

        if tile.isApplication, tile.isRunning {
            Button(String(localized: "New Window", comment: "Dock icon menu"), action: onNewWindow)
        }

        Menu(String(localized: "Options", comment: "Dock icon menu submenu")) {
            Button {
                onTogglePinned()
            } label: {
                Label(
                    String(localized: "Keep in Dock", comment: "Dock icon menu"),
                    systemImage: isPinned ? "checkmark" : ""
                )
            }
            Button {
                onToggleOpenAtLogin()
            } label: {
                Label(
                    String(localized: "Open at Login", comment: "Dock icon menu"),
                    systemImage: opensAtLogin ? "checkmark" : ""
                )
            }
            if tile.url != nil {
                Button(String(localized: "Show in Finder", comment: "Dock icon menu"), action: onReveal)
            }
        }

        Divider()

        if tile.isRunning {
            Button(String(localized: "Show All Windows", comment: "Dock icon menu"), action: onShowAllWindows)
            Button(String(localized: "Hide", comment: "Dock icon menu"), action: onHide)
            Divider()
            Button(String(localized: "Quit", comment: "Dock icon menu"), action: onQuit)
            Button(String(localized: "Force Quit", comment: "Dock icon menu"), action: onForceQuit)
        } else {
            Button(String(localized: "Open", comment: "Dock icon menu"), action: onOpen)
        }
    }
}
