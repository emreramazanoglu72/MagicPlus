//
//  FloatingPanel.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// Builds the chromeless floating panels used by the clipboard history and window switcher.
enum FloatingPanel {
    static func make(size: CGSize, title: String, content: some View) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    /// Borderless panel that never takes focus, for surfaces that appear on hover.
    static func makeNonActivating(size: CGSize, content: some View) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    /// Centres the panel on the screen holding the pointer, biased slightly above centre
    /// so it sits where the eye already is.
    static func center(_ panel: NSPanel, size: CGSize, verticalBias: CGFloat = 0.1) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2 + visibleFrame.height * verticalBias
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
    }
}
