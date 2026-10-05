//
//  MenuBarManagerView.swift
//  tabmenu
//

import SwiftUI

/// Menu bar tab of the popover: what is in each section, and the two commands that matter.
struct MenuBarManagerView: View {
    let service: MenuBarManagerService
    let preferences: Preferences
    let shortcut: HotKeyCombo?
    let onSearch: () -> Void
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if preferences.isMenuBarManagerEnabled {
                controls
                sections
                arrangeHint
            } else {
                disabledCard
            }
        }
        .onAppear { service.startLiveUpdates() }
        .onDisappear { service.stopLiveUpdates() }
    }

    private var isRevealed: Bool { service.isRevealed(.hidden) }

    private var controls: some View {
        GlassCard(tint: Accent.menuBar) {
            HStack(spacing: Metrics.tightSpacing) {
                Image(systemName: isRevealed ? "eye" : "eye.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(Accent.menuBar.gradient)
                    .symbolEffect(.bounce, value: isRevealed)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(isRevealed ? "Hidden items are showing" : "Hidden items are tucked away")
                        .font(.callout.weight(.medium))
                    Text("\(service.hiddenItemCount) items hidden")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Button(isRevealed ? "Hide" : "Show") {
                    service.toggleHiddenItems()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Accent.menuBar)
            }

            HStack(spacing: Metrics.tightSpacing) {
                Button {
                    onSearch()
                } label: {
                    Label("Search items", systemImage: "magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let shortcut {
                    Text(shortcut.displayString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                Button("Settings…") { SettingsWindow.open() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
        ForEach(MenuBarSection.allCases) { section in
            let items = service.items(in: section)
            if section != .alwaysHidden || preferences.usesAlwaysHiddenSection {
                VStack(alignment: .leading, spacing: Metrics.tightSpacing) {
                    SectionHeader(
                        title: section.title,
                        systemImage: section.symbolName,
                        tint: section.tint,
                        trailing: "\(items.count)"
                    )

                    if items.isEmpty {
                        Text(section == .visible ? "No items" : "Drag items here to hide them")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        itemRow(items)
                    }
                }
            }
        }
    }

    private func itemRow(_ items: [MenuBarItem]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    Button {
                        service.activate(item)
                    } label: {
                        VStack(spacing: 3) {
                            MenuBarItemIcon(item: item, images: service.images, size: 20)
                            Text(item.displayName)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 58)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(Text("\(item.displayName) — \(item.ownerName)"))
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var arrangeHint: some View {
        Label(
            "Hold ⌘ and drag an item across the divider to move it between sections.",
            systemImage: "hand.draw"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var disabledCard: some View {
        GlassCard(tint: .orange) {
            Label("Menu bar sections are off", systemImage: "eye.slash")
                .font(.callout.weight(.medium))
            Text("Turning this on adds a chevron and a divider to the menu bar. Items dragged to the left of the divider are hidden until you ask for them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On") { onEnable() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Accent.menuBar)
        }
    }
}
