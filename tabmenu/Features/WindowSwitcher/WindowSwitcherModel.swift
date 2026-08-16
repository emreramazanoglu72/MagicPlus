//
//  WindowSwitcherModel.swift
//  tabmenu
//

import AppKit
import Foundation
import Observation

/// One row of the switcher: an open window, or an app that could be opened.
enum SwitcherResult: Identifiable, Equatable {
    case window(SwitchableWindow)
    case app(LaunchableApp)

    var id: String {
        switch self {
        case .window(let window): "window-\(window.id)"
        case .app(let app): "app-\(app.id)"
        }
    }
}

@Observable
@MainActor
final class WindowSwitcherModel {
    var query = "" {
        didSet { clampSelection() }
    }
    private(set) var windows: [SwitchableWindow] = []
    private(set) var selectedIndex = 0

    @ObservationIgnored let thumbnails: WindowThumbnailService
    @ObservationIgnored var onActivate: ((SwitchableWindow) -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?

    init(thumbnails: WindowThumbnailService) {
        self.thumbnails = thumbnails
    }

    /// Matching windows first, then installed apps that are not already on screen — so the
    /// switcher doubles as a launcher without pushing a real window down the list.
    var results: [SwitcherResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matchedWindows = trimmed.isEmpty
            ? windows
            : windows.filter { $0.searchText.localizedCaseInsensitiveContains(trimmed) }

        let openBundleIdentifiers = Set(windows.compactMap(\.bundleIdentifier))
        let apps = AppLauncher.matches(for: trimmed, excluding: openBundleIdentifiers)

        return matchedWindows.map(SwitcherResult.window) + apps.map(SwitcherResult.app)
    }

    var selectedResult: SwitcherResult? {
        let results = results
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var selectedWindow: SwitchableWindow? {
        guard case .window(let window) = selectedResult else { return nil }
        return window
    }

    func thumbnail(for window: SwitchableWindow) -> NSImage? {
        thumbnails.thumbnail(for: window.windowID)
    }

    /// - Parameter preselectingPrevious: Starts on the second entry, matching the
    ///   expectation that one press of the switcher shortcut returns to the last window.
    func reload(preselectingPrevious: Bool) {
        query = ""
        windows = WindowLister.switchableWindows()
        selectedIndex = preselectingPrevious && windows.count > 1 ? 1 : 0
        thumbnails.refresh(windowIDs: windows.compactMap(\.windowID))
    }

    /// Wraps around, so holding the shortcut keeps cycling through every window.
    func moveSelection(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + offset) % count + count) % count
    }

    func select(_ result: SwitcherResult) {
        guard let index = results.firstIndex(of: result) else { return }
        selectedIndex = index
    }

    func activateSelection() {
        guard let result = selectedResult else { return }
        activate(result)
    }

    func activate(_ result: SwitcherResult) {
        switch result {
        case .window(let window):
            onActivate?(window)
        case .app(let app):
            AppLauncher.launch(app)
            onDismiss?()
        }
    }

    func dismiss() {
        onDismiss?()
    }

    // MARK: - Window actions

    func closeSelection() {
        guard let window = selectedWindow else { return }
        WindowLister.close(window)
        removeAfterAction(window)
    }

    func minimizeSelection() {
        guard let window = selectedWindow else { return }
        WindowLister.minimize(window)
        removeAfterAction(window)
    }

    func quitSelectedApplication() {
        guard let window = selectedWindow else { return }
        WindowLister.quitApplication(of: window)
        windows.removeAll { $0.processIdentifier == window.processIdentifier }
        clampSelection()
        if windows.isEmpty { dismiss() }
    }

    /// The window list is updated locally rather than re-read, so the panel does not flicker
    /// while the application tears the window down.
    private func removeAfterAction(_ window: SwitchableWindow) {
        windows.removeAll { $0.id == window.id }
        clampSelection()
        if windows.isEmpty { dismiss() }
    }

    private func clampSelection() {
        let count = results.count
        selectedIndex = count == 0 ? 0 : min(selectedIndex, count - 1)
    }
}
