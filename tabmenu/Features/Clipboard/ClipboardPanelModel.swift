//
//  ClipboardPanelModel.swift
//  tabmenu
//

import Observation

/// Drives the keyboard-first clipboard panel: query, selection, and the actions bound to keys.
@Observable
@MainActor
final class ClipboardPanelModel {
    var query = "" {
        didSet { clampSelection() }
    }
    private(set) var selectedIndex = 0

    @ObservationIgnored let service: ClipboardService
    @ObservationIgnored var onActivate: ((ClipboardItem) -> Void)?
    /// Fired after the pasteboard already holds the rewritten text.
    @ObservationIgnored var onActivateTransformed: ((ClipboardItem) -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?

    init(service: ClipboardService) {
        self.service = service
    }

    var results: [ClipboardItem] {
        service.filtered(by: query)
    }

    var selectedItem: ClipboardItem? {
        let results = results
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    func reset() {
        query = ""
        selectedIndex = 0
    }

    func select(_ item: ClipboardItem) {
        guard let index = results.firstIndex(where: { $0.id == item.id }) else { return }
        selectedIndex = index
    }

    func moveSelection(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), count - 1)
    }

    func activateSelection() {
        guard let item = selectedItem else { return }
        activate(item)
    }

    func activate(_ item: ClipboardItem) {
        onActivate?(item)
    }

    /// Transforms that would change the selected entry, or none for non-text entries.
    var availableTransforms: [ClipboardTransform] {
        guard let text = selectedItem?.plainText else { return [] }
        return ClipboardTransform.applicable(to: text)
    }

    func activateSelection(using transform: ClipboardTransform) {
        guard let item = selectedItem else { return }
        service.copyTransformed(item, using: transform)
        onActivateTransformed?(item)
    }

    func dismiss() {
        onDismiss?()
    }

    func togglePinSelection() {
        guard let item = selectedItem else { return }
        service.togglePin(item)
    }

    func deleteSelection() {
        guard let item = selectedItem else { return }
        service.delete(item)
        clampSelection()
    }

    private func clampSelection() {
        let count = results.count
        selectedIndex = count == 0 ? 0 : min(selectedIndex, count - 1)
    }
}
