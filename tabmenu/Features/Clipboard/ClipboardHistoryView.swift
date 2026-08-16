//
//  ClipboardHistoryView.swift
//  tabmenu
//

import SwiftUI

/// Compact history list embedded in the menu bar popover.
struct ClipboardHistoryView: View {
    let service: ClipboardService
    let preferences: Preferences
    let shortcut: HotKeyCombo?
    let onOpenPanel: () -> Void

    @State private var query = ""
    @State private var copiedItemID: ClipboardItem.ID?

    private var results: [ClipboardItem] {
        Array(service.filtered(by: query).prefix(50))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tightSpacing) {
            header

            if !preferences.isClipboardEnabled {
                pausedCard
            }

            searchField

            if results.isEmpty {
                emptyState
            } else {
                list
                footer
            }
        }
    }

    private var header: some View {
        HStack {
            SectionHeader(
                title: "Clipboard",
                systemImage: "doc.on.clipboard",
                tint: Accent.clipboard
            )
            Spacer()
            Button(action: onOpenPanel) {
                HStack(spacing: 4) {
                    Text("Open")
                    if let shortcut {
                        Text(shortcut.displayString).font(.caption2.monospaced())
                    }
                    Image(systemName: "arrow.up.forward")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Accent.clipboard)
            .help("Open the full clipboard panel")
        }
    }

    private var pausedCard: some View {
        GlassCard(tint: .orange) {
            Label("History is paused", systemImage: "pause.circle.fill")
                .font(.callout)
            Button("Resume") { preferences.isClipboardEnabled = true }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .glassEffect(in: .rect(cornerRadius: 9))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(results) { item in
                    Button {
                        copy(item)
                    } label: {
                        ClipboardRow(item: item, thumbnail: service.image(for: item))
                            .overlay(alignment: .trailing) {
                                if copiedItemID == item.id {
                                    Label("Copied", systemImage: "checkmark.circle.fill")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.green)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                    }
                    .buttonStyle(PanelRowButtonStyle())
                    .contextMenu {
                        Button(item.isPinned ? "Unpin" : "Pin") { service.togglePin(item) }
                        Button("Delete", role: .destructive) { service.delete(item) }
                    }
                }
            }
        }
        .frame(maxHeight: 240)
        .motion(Motion.snappy, value: copiedItemID)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private var footer: some View {
        HStack {
            Text("\(service.items.count) items")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Clear") { service.clearHistory() }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Remove all unpinned items")
        }
    }

    /// Copies and briefly confirms inline, so the popover does not have to close to give feedback.
    private func copy(_ item: ClipboardItem) {
        service.copyToPasteboard(item)
        copiedItemID = item.id
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if copiedItemID == item.id { copiedItemID = nil }
        }
    }
}
