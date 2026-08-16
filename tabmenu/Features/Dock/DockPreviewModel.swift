//
//  DockPreviewModel.swift
//  tabmenu
//

import AppKit
import Observation

/// State behind the Dock preview panel: which application is hovered and its open windows.
@Observable
@MainActor
final class DockPreviewModel {
    private(set) var item: DockItem?
    private(set) var windows: [SwitchableWindow] = []

    @ObservationIgnored let thumbnails: WindowThumbnailService
    @ObservationIgnored var onWindowFocused: (() -> Void)?

    init(thumbnails: WindowThumbnailService) {
        self.thumbnails = thumbnails
    }

    var applicationName: String { item?.title ?? "" }

    /// Loads the windows for a Dock icon. Returns `false` when there is nothing to preview.
    @discardableResult
    func present(_ item: DockItem) -> Bool {
        guard let processIdentifier = item.processIdentifier else { return false }
        let windows = WindowLister.windows(ofProcessIdentifier: processIdentifier)
        guard !windows.isEmpty else { return false }

        self.item = item
        self.windows = windows
        thumbnails.refresh(windowIDs: windows.compactMap(\.windowID))
        return true
    }

    func clear() {
        item = nil
        windows = []
    }

    func thumbnail(for window: SwitchableWindow) -> NSImage? {
        thumbnails.thumbnail(for: window.windowID)
    }

    // MARK: - Actions

    func focus(_ window: SwitchableWindow) {
        WindowLister.focus(window)
        onWindowFocused?()
    }

    func close(_ window: SwitchableWindow) {
        WindowLister.close(window)
        reloadAfterAction()
    }

    func minimize(_ window: SwitchableWindow) {
        WindowLister.minimize(window)
        reloadAfterAction()
    }

    func quitApplication() {
        guard let window = windows.first else { return }
        WindowLister.quitApplication(of: window)
        onWindowFocused?()
    }

    /// Applications need a moment to tear a window down before the list reflects it.
    private func reloadAfterAction() {
        guard let item, let processIdentifier = item.processIdentifier else { return }
        let itemID = item.id
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            // The panel may have moved on to another Dock icon while we slept.
            guard self.item?.id == itemID else { return }
            let refreshed = WindowLister.windows(ofProcessIdentifier: processIdentifier)
            windows = refreshed
            if refreshed.isEmpty {
                onWindowFocused?()
            } else {
                thumbnails.refresh(windowIDs: refreshed.compactMap(\.windowID))
            }
        }
    }
}
