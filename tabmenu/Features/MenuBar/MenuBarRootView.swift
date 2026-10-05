//
//  MenuBarRootView.swift
//  tabmenu
//

import SwiftUI

struct MenuBarRootView: View {
    let environment: AppEnvironment

    @AppStorage("menuBar.selectedTab") private var selectedTab: MenuBarTab = .windows
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabHighlight

    /// Tabs for modules that are switched on. A tab for something that is not running would be a
    /// tab with nothing behind it.
    private var visibleTabs: [MenuBarTab] {
        MenuBarTab.allCases.filter { tab in
            guard let module = tab.module else { return true }
            return environment.preferences.isEnabled(module)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            header
            if !visibleTabs.isEmpty { tabBar }

            ScrollView {
                content
                    .padding(.bottom, 4)
                    .id(selectedTab)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        )
                    )
            }
            .scrollBounceBehavior(.basedOnSize)
            .motion(Motion.transition, value: selectedTab)
        }
        .padding(12)
        .frame(width: Metrics.panelWidth)
        .frame(maxHeight: 560)
        .onAppear(perform: selectSomethingVisible)
        .onChange(of: visibleTabs, selectSomethingVisible)
    }

    /// A selection remembered from before a module was switched off would leave the popover
    /// showing nothing at all.
    private func selectSomethingVisible() {
        guard !visibleTabs.contains(selectedTab), let first = visibleTabs.first else { return }
        selectedTab = first
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 13))
                .foregroundStyle(selectedTab.tint.gradient)
                .motion(Motion.fluid, value: selectedTab)

            Text("MagicPlus")
                .font(.headline)

            Spacer()

            KeepAwakeHeaderButton(service: environment.keepAwake)
            HeaderButton(systemImage: "gearshape", help: "Settings") {
                SettingsWindow.open()
            }
            HeaderButton(systemImage: "power", help: "Quit MagicPlus") {
                NSApp.terminate(nil)
            }
        }
    }

    /// Icon-only tabs that expand to reveal their title when selected, with the glass
    /// highlight sliding between them.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(visibleTabs) { tab in
                Button {
                    withMotion(Motion.fluid, reduceMotion: reduceMotion) { selectedTab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 12, weight: .medium))
                            .symbolEffect(.bounce, value: selectedTab == tab)
                        if selectedTab == tab {
                            Text(tab.title)
                                .font(.caption.weight(.semibold))
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? AnyShapeStyle(tab.tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, selectedTab == tab ? 11 : 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: selectedTab == tab ? .infinity : nil)
                    .background {
                        if selectedTab == tab {
                            Capsule()
                                .fill(tab.tint.opacity(0.2))
                                .matchedGeometryEffect(id: "tabHighlight", in: tabHighlight)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .glassEffect(in: .capsule)
        .motion(Motion.fluid, value: selectedTab)
    }

    /// Every module with a tab can be switched off at once, which would otherwise leave the last
    /// selection on screen — a pane for something that is not running.
    private var everythingOff: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Nothing switched on")
                .font(.callout.weight(.medium))
            Text("Turn a module on in Settings and it appears here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { SettingsWindow.open() }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    @ViewBuilder
    private var content: some View {
        if visibleTabs.isEmpty {
            everythingOff
        } else {
            paneForSelectedTab
        }
    }

    @ViewBuilder
    private var paneForSelectedTab: some View {
        switch selectedTab {
        case .windows:
            WindowManagerView(
                service: environment.windowManager,
                preferences: environment.preferences,
                permission: environment.permission,
                layouts: environment.layouts,
                onSwitchWindows: { environment.windowSwitcher.show() }
            )
        case .clipboard:
            ClipboardHistoryView(
                service: environment.clipboard,
                preferences: environment.preferences,
                shortcut: environment.preferences.shortcut(for: .showClipboard),
                onOpenPanel: { environment.clipboardPanel.show() }
            )
        case .downloads:
            DownloadsCard(
                store: environment.downloads.store,
                onAddLink: { environment.downloads.showManualEntry() }
            )
        case .menuBar:
            MenuBarManagerView(
                service: environment.menuBarManager,
                preferences: environment.preferences,
                shortcut: environment.preferences.shortcut(for: .searchMenuBarItems),
                onSearch: { environment.menuBarSearch.show() },
                onEnable: {
                    environment.preferences.isMenuBarManagerEnabled = true
                    environment.menuBarManager.updateConfiguration()
                }
            )
        case .stats:
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                KeepAwakeCard(service: environment.keepAwake)
                SystemMonitorView(service: environment.monitor)
                SensorsCard(service: environment.hardware)
                BatteryCard(
                    service: environment.hardware,
                    chargeLimit: environment.chargeLimit,
                    onOpenSettings: { SettingsWindow.open() }
                )
            }
        }
    }
}

private struct HeaderButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background(.quaternary.opacity(isHovered ? 0.7 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }
}

enum MenuBarTab: String, CaseIterable, Identifiable {
    case windows, clipboard, downloads, menuBar, stats

    var id: String { rawValue }

    /// Shown inside the selected tab pill, which only expands so far.
    var title: String {
        switch self {
        case .windows: String(localized: "Windows", comment: "Popover tab: window management")
        case .clipboard: String(localized: "Clipboard", comment: "Popover tab: clipboard history")
        case .downloads: String(localized: "Downloads", comment: "Popover tab: the download queue")
        case .menuBar: String(localized: "Menu Bar", comment: "Popover tab: menu bar sections")
        case .stats: String(localized: "Stats", comment: "Popover tab: system monitor")
        }
    }

    var symbolName: String {
        switch self {
        case .windows: "macwindow.on.rectangle"
        case .clipboard: "doc.on.clipboard"
        case .downloads: "arrow.down.circle"
        case .menuBar: "menubar.rectangle"
        case .stats: "waveform.path.ecg"
        }
    }

    /// The module this tab belongs to, so a tab for something switched off is not offered.
    var module: AppModule? {
        switch self {
        case .windows: .windows
        case .clipboard: .clipboard
        case .downloads: .downloads
        case .menuBar: .menuBar
        case .stats: .systemMonitor
        }
    }

    var tint: Color {
        switch self {
        case .windows: Accent.windows
        case .clipboard: Accent.clipboard
        case .downloads: Accent.network
        case .menuBar: Accent.menuBar
        case .stats: .green
        }
    }
}
