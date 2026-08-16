//
//  MenuPalettePanel.swift
//  tabmenu
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Command-palette state: the frontmost app's menu commands, filtered by the query.
@Observable
@MainActor
final class MenuPaletteModel {
    var query = "" {
        didSet { selectedIndex = 0 }
    }
    private(set) var commands: [MenuCommand] = []
    private(set) var selectedIndex = 0
    private(set) var applicationName = ""

    @ObservationIgnored var onExecute: ((MenuCommand) -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?

    var results: [MenuCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(commands.prefix(40)) }

        return commands
            .compactMap { command -> (MenuCommand, Int)? in
                guard let score = MenuTreeReader.score(query: trimmed, title: command.title, path: command.path)
                else { return nil }
                return (command, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(40)
            .map(\.0)
    }

    var selectedCommand: MenuCommand? {
        let results = results
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    func load(from application: NSRunningApplication) {
        applicationName = application.localizedName ?? ""
        commands = MenuTreeReader.commands(forProcessIdentifier: application.processIdentifier)
        query = ""
        selectedIndex = 0
    }

    func moveSelection(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + offset) % count + count) % count
    }

    func select(_ command: MenuCommand) {
        guard let index = results.firstIndex(of: command) else { return }
        selectedIndex = index
    }

    func executeSelection() {
        guard let command = selectedCommand, command.isEnabled else { return }
        onExecute?(command)
    }

    func execute(_ command: MenuCommand) {
        guard command.isEnabled else { return }
        onExecute?(command)
    }

    func dismiss() {
        onDismiss?()
    }
}

/// Presents the palette over the frontmost app and runs the chosen menu item.
@MainActor
final class MenuPalettePanelController: NSObject, NSWindowDelegate {
    private let model = MenuPaletteModel()
    private let frontmostTracker: FrontmostApplicationTracker
    private let permission: AccessibilityPermission

    private var panel: NSPanel?
    private var keyMonitor: Any?
    /// `orderOut` fires `windowDidResignKey` synchronously, which must not re-enter `hide()`.
    private var isHiding = false

    private static let panelSize = CGSize(width: 560, height: 380)
    /// The restored app needs a moment to become key before the press lands.
    private static let executeDelay: Duration = .milliseconds(140)

    init(frontmostTracker: FrontmostApplicationTracker, permission: AccessibilityPermission? = nil) {
        self.frontmostTracker = frontmostTracker
        self.permission = permission ?? .shared
        super.init()

        model.onExecute = { [weak self] command in self?.execute(command) }
        model.onDismiss = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard permission.isTrusted else {
            permission.request()
            return
        }

        // The menu tree must be read from the app the user was in, before our panel
        // becomes frontmost and changes the answer.
        frontmostTracker.remember()
        guard let target = frontmostTracker.lastExternalApplication else { return }
        model.load(from: target)

        let panel = panel ?? makePanel()
        self.panel = panel
        FloatingPanel.center(panel, size: Self.panelSize)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyMonitor()
    }

    func hide(restoringPreviousApplication: Bool = true) {
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }

        stopKeyMonitor()
        panel?.orderOut(nil)
        if restoringPreviousApplication { frontmostTracker.restore() }
    }

    /// The target app must be frontmost again before the menu press, or items that act on
    /// the active window act on nothing.
    private func execute(_ command: MenuCommand) {
        hide()
        Task {
            try? await Task.sleep(for: Self.executeDelay)
            MenuTreeReader.execute(command)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel.make(
            size: Self.panelSize,
            title: String(localized: "Search Menus", comment: "Floating panel title"),
            content: MenuPaletteView(model: model)
        )
        panel.delegate = self
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        // The user clicked elsewhere; raising the previous app would steal that focus.
        hide(restoringPreviousApplication: false)
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
            model.executeSelection()
            return true
        default:
            return false
        }
    }
}

/// Spotlight-style list of the frontmost app's menu commands.
struct MenuPaletteView: View {
    @Bindable var model: MenuPaletteModel
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
            Image(systemName: "filemenu.and.selection")
                .font(.system(size: 14))
                .foregroundStyle(Accent.windows.gradient)

            TextField("Search menu commands…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit { model.executeSelection() }

            if !model.applicationName.isEmpty {
                Text(model.applicationName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: .capsule)
            }
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
                Text(model.commands.isEmpty ? "No menus could be read" : "No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            let isSelected = index == model.selectedIndex

                            Button {
                                model.execute(command)
                            } label: {
                                HStack(spacing: 9) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(command.title)
                                            .font(.callout)
                                            .foregroundStyle(command.isEnabled ? .primary : .tertiary)
                                        Text(command.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    if isSelected, command.isEnabled {
                                        Image(systemName: "return")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(PanelRowButtonStyle())
                            .disabled(!command.isEnabled)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(Accent.windows.opacity(0.22))
                                        .matchedGeometryEffect(id: "paletteSelection", in: selectionHighlight)
                                }
                            }
                            .onHover { if $0 { model.select(command) } }
                            .id(command.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .motion(Motion.fluid, value: model.selectedIndex)
                .onChange(of: model.selectedIndex) { _, index in
                    guard results.indices.contains(index) else { return }
                    withAnimation(Motion.snappy) {
                        proxy.scrollTo(results[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(keys: "↑↓", label: "Navigate")
            KeyHint(keys: "↩", label: "Run")
            Spacer()
            KeyHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
    }
}
