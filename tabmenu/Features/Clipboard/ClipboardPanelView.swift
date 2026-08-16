//
//  ClipboardPanelView.swift
//  tabmenu
//

import SwiftUI

/// Spotlight-style clipboard browser: searchable list on the left, live preview on the right.
struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel
    @FocusState private var isSearchFocused: Bool
    @Namespace private var selectionHighlight

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.5)

            HStack(spacing: 0) {
                list
                    .frame(width: 300)
                Divider().opacity(0.5)
                ClipboardPreviewPane(
                    item: model.selectedItem,
                    image: model.selectedItem.flatMap { model.service.image(for: $0) },
                    transforms: model.availableTransforms,
                    onPaste: { model.activateSelection() },
                    onTogglePin: { model.togglePinSelection() },
                    onDelete: { model.deleteSelection() },
                    onTransform: { model.activateSelection(using: $0) }
                )
            }

            Divider().opacity(0.5)
            footer
        }
        .background(.ultraThickMaterial)
        .onAppear { isSearchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 14))
                .foregroundStyle(Accent.clipboard.gradient)
                .symbolEffect(.bounce, value: model.results.count)

            TextField("Search clipboard…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit { model.activateSelection() }

            if !model.query.isEmpty {
                Text("\(model.results.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .motion(Motion.snappy, value: model.results.count)

                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var list: some View {
        let results = model.results
        if results.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            let isSelected = index == model.selectedIndex

                            Button {
                                model.activate(item)
                            } label: {
                                ClipboardRow(
                                    item: item,
                                    thumbnail: model.service.image(for: item),
                                    isSelected: isSelected
                                )
                            }
                            .buttonStyle(PanelRowButtonStyle())
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(Accent.clipboard.opacity(0.22))
                                        .matchedGeometryEffect(id: "clipboardSelection", in: selectionHighlight)
                                }
                            }
                            .onHover { hovering in
                                if hovering { model.select(item) }
                            }
                            .id(item.id)
                            .contextMenu {
                                Button(item.isPinned ? "Unpin" : "Pin") { model.service.togglePin(item) }
                                Button("Copy") { model.service.copyToPasteboard(item) }
                                Divider()
                                Button("Delete", role: .destructive) { model.service.delete(item) }
                            }
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse)
            Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(keys: "↑↓", label: "Navigate")
            KeyHint(keys: "↩", label: "Paste")
            KeyHint(keys: "⌘P", label: "Pin")
            KeyHint(keys: "⌘⌫", label: "Delete")
            Spacer()
            KeyHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
    }
}
