//
//  MenuBarSearchPanel.swift
//  tabmenu
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Search state over everything in the menu bar, hidden items included.
@Observable
@MainActor
final class MenuBarSearchModel {
    var query = "" {
        didSet { selectedIndex = 0 }
    }
    private(set) var selectedIndex = 0

    @ObservationIgnored let service: MenuBarManagerService
    @ObservationIgnored var onActivate: ((MenuBarItem) -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?

    init(service: MenuBarManagerService) {
        self.service = service
    }

    /// Every item, ordered by section so the ones the user cannot see come first: those are
    /// the ones worth searching for.
    private var allItems: [(item: MenuBarItem, section: MenuBarSection)] {
        [MenuBarSection.hidden, .alwaysHidden, .visible].flatMap { section in
            service.items(in: section).map { ($0, section) }
        }
    }

    var results: [(item: MenuBarItem, section: MenuBarSection)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allItems }

        return allItems
            .compactMap { entry -> ((item: MenuBarItem, section: MenuBarSection), Int)? in
                guard let score = MenuTreeReader.score(
                    query: trimmed,
                    title: entry.item.displayName,
                    path: entry.item.ownerName
                ) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func moveSelection(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + offset) % count + count) % count
    }

    func select(_ item: MenuBarItem) {
        guard let index = results.firstIndex(where: { $0.item.id == item.id }) else { return }
        selectedIndex = index
    }

    func activateSelection() {
        guard results.indices.contains(selectedIndex) else { return }
        onActivate?(results[selectedIndex].item)
    }

    func activate(_ item: MenuBarItem) {
        onActivate?(item)
    }

    func dismiss() {
        onDismiss?()
    }
}

/// Spotlight-style search over the menu bar. Picking a result clicks the real item, folding
/// its section back out of hiding first if that is where it lives.
@MainActor
final class MenuBarSearchPanelController: NSObject, NSWindowDelegate {
    private let model: MenuBarSearchModel
    private let service: MenuBarManagerService

    private var panel: NSPanel?
    private var keyMonitor: Any?
    /// `orderOut` fires `windowDidResignKey` synchronously, which must not re-enter `hide()`.
    private var isHiding = false
    private var isLive = false

    private static let panelSize = CGSize(width: 480, height: 400)
    /// The panel has to be out of the way before the click lands, or it takes it instead.
    private static let activationDelay: Duration = .milliseconds(120)

    init(service: MenuBarManagerService) {
        self.service = service
        self.model = MenuBarSearchModel(service: service)
        super.init()

        model.onActivate = { [weak self] item in self?.activate(item) }
        model.onDismiss = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        service.refreshItems()
        service.images.refresh(for: service.items, force: true)
        model.query = ""

        let panel = panel ?? makePanel()
        self.panel = panel
        FloatingPanel.center(panel, size: Self.panelSize)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyMonitor()
        if !isLive {
            isLive = true
            service.startLiveUpdates()
        }
    }

    func hide() {
        guard !isHiding, isVisible else { return }
        isHiding = true
        defer { isHiding = false }

        stopKeyMonitor()
        panel?.orderOut(nil)
        if isLive {
            isLive = false
            service.stopLiveUpdates()
        }
    }

    private func activate(_ item: MenuBarItem) {
        hide()
        Task { [service] in
            try? await Task.sleep(for: Self.activationDelay)
            service.activate(item)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel.make(
            size: Self.panelSize,
            title: String(localized: "Search Menu Bar Items", comment: "Floating panel title"),
            content: MenuBarSearchView(model: model)
        )
        panel.delegate = self
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

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
        default:
            return false
        }
    }
}

struct MenuBarSearchView: View {
    @Bindable var model: MenuBarSearchModel
    @FocusState private var isSearchFocused: Bool
    @Namespace private var selectionHighlight

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .background(.ultraThickMaterial)
        .onAppear { isSearchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "menubar.dock.rectangle")
                .font(.system(size: 14))
                .foregroundStyle(Accent.menuBar.gradient)

            TextField("Search menu bar items…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit { model.activateSelection() }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var content: some View {
        let results = model.results
        if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "No menu bar items found" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.item.id) { index, entry in
                            row(for: entry, isSelected: index == model.selectedIndex)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .motion(Motion.fluid, value: model.selectedIndex)
                .onChange(of: model.selectedIndex) { _, index in
                    guard results.indices.contains(index) else { return }
                    withAnimation(Motion.snappy) {
                        proxy.scrollTo(results[index].item.id, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(for entry: (item: MenuBarItem, section: MenuBarSection), isSelected: Bool) -> some View {
        Button {
            model.activate(entry.item)
        } label: {
            HStack(spacing: 10) {
                MenuBarItemIcon(item: entry.item, images: model.service.images, size: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.item.displayName)
                        .font(.callout)
                    Text(entry.item.ownerName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Text(entry.section.title)
                    .font(.caption2)
                    .foregroundStyle(entry.section.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(entry.section.tint.opacity(0.16), in: .capsule)

                if isSelected {
                    Image(systemName: "return")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PanelRowButtonStyle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Accent.menuBar.opacity(0.22))
                    .matchedGeometryEffect(id: "menuBarSearchSelection", in: selectionHighlight)
            }
        }
        .onHover { if $0 { model.select(entry.item) } }
        .id(entry.item.id)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(keys: "↑↓", label: "Navigate")
            KeyHint(keys: "↩", label: "Click")
            Spacer()
            KeyHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
    }
}
