//
//  WindowSwitcherPanelView.swift
//  tabmenu
//

import SwiftUI

struct WindowSwitcherPanelView: View {
    @Bindable var model: WindowSwitcherModel
    let layout: SwitcherLayout
    let showsThumbnails: Bool

    @FocusState private var isSearchFocused: Bool
    @Namespace private var selectionHighlight

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

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
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 14))
                .foregroundStyle(Accent.windows.gradient)

            TextField("Search windows…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit { model.activateSelection() }

            Text("\(model.results.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .motion(Motion.snappy, value: model.results.count)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var content: some View {
        let results = model.results
        if results.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    switch layout {
                    case .grid: grid(results)
                    case .list: list(results)
                    }
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

    private func grid(_ results: [SwitcherResult]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 10) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                Button {
                    model.activate(result)
                } label: {
                    switch result {
                    case .window(let window):
                        SwitcherPreviewCard(
                            window: window,
                            thumbnail: showsThumbnails ? model.thumbnail(for: window) : nil,
                            isSelected: index == model.selectedIndex
                        )
                    case .app(let app):
                        AppCard(app: app, isSelected: index == model.selectedIndex)
                    }
                }
                .buttonStyle(.plain)
                .onHover { if $0 { model.select(result) } }
                .id(result.id)
            }
        }
        .padding(12)
    }

    private func list(_ results: [SwitcherResult]) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                let isSelected = index == model.selectedIndex

                Button {
                    model.activate(result)
                } label: {
                    switch result {
                    case .window(let window):
                        WindowSwitcherRow(window: window, isSelected: isSelected)
                    case .app(let app):
                        AppRow(app: app, isSelected: isSelected)
                    }
                }
                .buttonStyle(PanelRowButtonStyle())
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Accent.windows.opacity(0.22))
                            .matchedGeometryEffect(id: "switcherSelection", in: selectionHighlight)
                    }
                }
                .onHover { if $0 { model.select(result) } }
                .id(result.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.query.isEmpty ? "macwindow" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse)
            Text(model.query.isEmpty ? "No open windows found" : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(keys: "⇥ / ↓", label: "Next")
            KeyHint(keys: "↩", label: "Switch or open")
            KeyHint(keys: "⌘W", label: "Close")
            KeyHint(keys: "⌘M", label: "Minimise")
            Spacer()
            KeyHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
    }
}

/// Grid card with a live preview of the window.
private struct SwitcherPreviewCard: View {
    let window: SwitchableWindow
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary.opacity(0.5))
                        if let icon = window.applicationIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 40, height: 40)
                        }
                    }
                }
            }
            .frame(height: 118)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Accent.windows : .white.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .shadow(color: .black.opacity(isSelected ? 0.4 : 0.15), radius: isSelected ? 9 : 3, y: 2)

            HStack(spacing: 5) {
                if let icon = window.applicationIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(window.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(window.applicationName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(6)
        .background(isSelected ? Accent.windows.opacity(0.16) : .clear, in: .rect(cornerRadius: 12))
        .scaleEffect(isSelected ? 1.02 : 1)
        .motion(Motion.snappy, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.applicationName): \(window.title)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// An installed app that is not running: shown after the windows, clearly a launch action.
private struct AppCard: View {
    let app: LaunchableApp
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.4))
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 54, height: 54)
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
            .frame(height: 118)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Accent.windows : .white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(app.name)
                    .font(.caption)
                    .lineLimit(1)
                Text("Open")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(isSelected ? Accent.windows.opacity(0.16) : .clear, in: .rect(cornerRadius: 12))
        .scaleEffect(isSelected ? 1.02 : 1)
        .motion(Motion.snappy, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open \(app.name)")
    }
}

private struct AppRow: View {
    let app: LaunchableApp
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: isSelected ? 32 : 28, height: isSelected ? 32 : 28)
                .motion(Motion.snappy, value: isSelected)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.callout)
                    .lineLimit(1)
                Text("Open")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Image(systemName: "arrow.up.forward.app")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open \(app.name)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct WindowSwitcherRow: View {
    let window: SwitchableWindow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let applicationIcon = window.applicationIcon {
                    Image(nsImage: applicationIcon).resizable()
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit()
                }
            }
            .frame(width: isSelected ? 32 : 28, height: isSelected ? 32 : 28)
            .shadow(color: .black.opacity(isSelected ? 0.3 : 0), radius: 4, y: 2)
            .motion(Motion.snappy, value: isSelected)

            VStack(alignment: .leading, spacing: 1) {
                Text(window.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(window.applicationName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if window.isMinimized {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Minimised")
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.applicationName): \(window.title)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
