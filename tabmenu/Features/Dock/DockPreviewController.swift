//
//  DockPreviewController.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// Shows window previews above the hovered Dock icon and keeps them open while the pointer
/// travels between the icon and the panel.
@MainActor
final class DockPreviewController {
    private let model: DockPreviewModel
    private let preferences: Preferences
    private let permission: AccessibilityPermission
    private let monitor = DockHoverMonitor()

    private var panel: NSPanel?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var presentedItemID: String?

    private static let cardWidth: CGFloat = 184
    private static let panelHeight: CGFloat = 176
    private static let maximumPanelWidth: CGFloat = 900
    /// Grace period so the pointer can cross the gap between icon and panel.
    private static let closeDelay: Duration = .milliseconds(280)

    init(
        thumbnails: WindowThumbnailService,
        preferences: Preferences,
        permission: AccessibilityPermission? = nil
    ) {
        self.model = DockPreviewModel(thumbnails: thumbnails)
        self.preferences = preferences
        self.permission = permission ?? .shared

        model.onWindowFocused = { [weak self] in self?.hide() }
        monitor.onMove = { [weak self] location, item in
            self?.handle(location: location, item: item)
        }
    }

    // MARK: - Lifecycle

    func updateMonitoring() {
        let shouldRun = preferences.isDockPreviewEnabled && permission.isTrusted
        if shouldRun {
            monitor.start()
        } else {
            monitor.stop()
            hide()
        }
    }

    func stop() {
        monitor.stop()
        hide()
    }

    // MARK: - Hover handling

    private func handle(location: CGPoint, item: DockItem?) {
        if let item, item.isRunning {
            cancelClose()
            guard item.id != presentedItemID else { return }
            scheduleOpen(item)
            return
        }

        cancelOpen()

        if let panel, panel.isVisible, panel.frame.insetBy(dx: -12, dy: -12).contains(location) {
            cancelClose()
            return
        }

        scheduleClose()
    }

    private func scheduleOpen(_ item: DockItem) {
        cancelOpen()
        let delay = Duration.milliseconds(Int(preferences.dockHoverDelay * 1000))
        openTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.present(item)
        }
    }

    private func scheduleClose() {
        guard closeTask == nil, panel?.isVisible == true else { return }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func cancelOpen() {
        openTask?.cancel()
        openTask = nil
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    // MARK: - Presentation

    private func present(_ item: DockItem) {
        guard model.present(item) else {
            hide()
            return
        }
        presentedItemID = item.id

        let size = panelSize(forWindowCount: model.windows.count)
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(size)
        position(panel, near: item, size: size)
        panel.orderFrontRegardless()
    }

    private func hide() {
        cancelOpen()
        cancelClose()
        presentedItemID = nil
        panel?.orderOut(nil)
        model.clear()
    }

    private func makePanel() -> NSPanel {
        FloatingPanel.makeNonActivating(
            size: CGSize(width: Self.maximumPanelWidth, height: Self.panelHeight),
            content: DockPreviewView(
                model: model,
                preferences: preferences
            )
        )
    }

    private func panelSize(forWindowCount count: Int) -> CGSize {
        let contentWidth = CGFloat(count) * Self.cardWidth + 24
        return CGSize(
            width: min(max(contentWidth, 220), Self.maximumPanelWidth),
            height: Self.panelHeight
        )
    }

    /// Places the panel outside the Dock, on whichever edge the Dock currently occupies.
    private func position(_ panel: NSPanel, near item: DockItem, size: CGSize) {
        let iconFrame = item.frame.flippedBetweenScreenSpaces()
        let screen = NSScreen.screens.first { $0.frame.intersects(iconFrame) } ?? NSScreen.main
        guard let visibleFrame = screen?.frame else { return }

        let dockFrame = DockItemLister.dockFrame()?.flippedBetweenScreenSpaces()
        let isVerticalDock = (dockFrame?.height ?? 0) > (dockFrame?.width ?? 1)

        var origin: CGPoint
        if isVerticalDock {
            let isLeftEdge = (dockFrame?.midX ?? 0) < visibleFrame.midX
            origin = CGPoint(
                x: isLeftEdge ? iconFrame.maxX + 10 : iconFrame.minX - size.width - 10,
                y: iconFrame.midY - size.height / 2
            )
        } else {
            let isBottomDock = (dockFrame?.midY ?? 0) < visibleFrame.midY
            origin = CGPoint(
                x: iconFrame.midX - size.width / 2,
                y: isBottomDock ? iconFrame.maxY + 10 : iconFrame.minY - size.height - 10
            )
        }

        origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)

        panel.setFrame(CGRect(origin: origin, size: size), display: false)
    }
}
