//
//  WindowManagerView.swift
//  MagicPlus
//

import AppKit
import SwiftUI

/// The Windows tab: a miniature desktop that *is* the control.
///
/// Instead of a grid of abstract buttons, the screen preview is divided into nine hotspots —
/// corners snap to quarters, edges to halves, the middle maximizes. Hovering shows exactly
/// where the window will land; clicking sends it there, and clicking again cycles the widths.
struct WindowManagerView: View {
    let service: WindowManagerService
    let preferences: Preferences
    let permission: AccessibilityPermission
    let layouts: WorkspaceLayoutStore
    let onSwitchWindows: () -> Void

    @State private var hoveredAction: WindowAction?
    @State private var lastAppliedAction: WindowAction?
    @State private var isPulsing = false
    @State private var isNamingLayout = false
    @State private var layoutName = ""
    @FocusState private var isLayoutFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hotspot layout mirrored onto the preview: row-major, centre is maximize.
    private static let hotspotGrid: [[WindowAction]] = [
        [.topLeft, .top, .topRight],
        [.left, .maximize, .right],
        [.bottomLeft, .bottom, .bottomRight]
    ]

    private var previewAction: WindowAction {
        hoveredAction ?? lastAppliedAction ?? .maximize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if !permission.isTrusted {
                AccessibilityPromptCard(permission: permission)
            }

            switcherRow
            interactivePreview
            captionRow
            pillRow

            if let failure = service.lastFailure, permission.isTrusted {
                Label(failure.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            layoutSection
        }
        .motion(Motion.transition, value: service.lastFailure)
    }

    // MARK: - Switcher entry

    private var switcherRow: some View {
        Button(action: onSwitchWindows) {
            HStack(spacing: 7) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Accent.windows)
                Text("Switch Windows")
                    .font(.callout)
                Spacer()
                if let shortcut = preferences.shortcut(for: .switchWindows) {
                    Text(shortcut.displayString)
                        .font(.caption2.monospaced().weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 4))
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Accent.windows.opacity(0.14)).interactive(), in: .rect(cornerRadius: 11))
        .disabled(!permission.isTrusted)
        .help("Browse and search every open window")
    }

    // MARK: - The screen itself, as the control

    private var interactivePreview: some View {
        ScreenPreview(
            zone: previewAction.cycle.first,
            gap: preferences.windowGap,
            isEmphasised: isPulsing
        )
        .overlay { hotspots }
        .onHover { inside in
            if !inside {
                withMotion(Motion.snappy, reduceMotion: reduceMotion) { hoveredAction = nil }
            }
        }
    }

    /// Nine invisible targets over the mini desktop. The window chrome inside the preview is
    /// the hover feedback: it springs to wherever the pointer would send it.
    private var hotspots: some View {
        GeometryReader { proxy in
            let cellWidth = proxy.size.width / 3
            let cellHeight = proxy.size.height / 3

            ForEach(0..<3, id: \.self) { row in
                ForEach(0..<3, id: \.self) { column in
                    let action = Self.hotspotGrid[row][column]

                    Button {
                        apply(action)
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(hoveredAction == action ? 0.07 : 0.0001))
                            .overlay {
                                if hoveredAction == action {
                                    Image(systemName: action.symbolName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .shadow(color: .black.opacity(0.6), radius: 3)
                                        .transition(.opacity)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .frame(width: cellWidth, height: cellHeight)
                    .position(
                        x: cellWidth * (CGFloat(column) + 0.5),
                        y: cellHeight * (CGFloat(row) + 0.5)
                    )
                    .onHover { hovering in
                        withMotion(Motion.snappy, reduceMotion: reduceMotion) {
                            if hovering {
                                hoveredAction = action
                            } else if hoveredAction == action {
                                hoveredAction = nil
                            }
                        }
                    }
                    .disabled(!permission.isTrusted)
                    .help(helpText(for: action))
                    .accessibilityLabel(action.title)
                }
            }
        }
        .motion(Motion.snappy, value: hoveredAction)
    }

    private var captionRow: some View {
        HStack(spacing: 4) {
            Image(systemName: previewAction.symbolName)
                .font(.caption2)
                .foregroundStyle(Accent.windows)
            Text(previewAction.title)
                .font(.caption.weight(.medium))
            if previewAction.cycle.count > 1 {
                Text("· click again to cycle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let shortcut = preferences.shortcut(for: .window(previewAction)) {
                Text(shortcut.displayString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .contentTransition(.opacity)
        .motion(Motion.snappy, value: previewAction)
        .accessibilityHidden(true)
    }

    // MARK: - Centre, restore, gap

    private var pillRow: some View {
        HStack(spacing: 6) {
            ActionPill(
                title: WindowAction.center.title,
                systemImage: WindowAction.center.symbolName,
                isEnabled: permission.isTrusted
            ) {
                apply(.center)
            }
            ActionPill(
                title: WindowAction.restore.title,
                systemImage: WindowAction.restore.symbolName,
                isEnabled: permission.isTrusted
            ) {
                apply(.restore)
            }

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "arrow.left.and.right.square")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { preferences.windowGap },
                        set: { preferences.windowGap = $0 }
                    ),
                    in: 0...24,
                    step: 2
                )
                .controlSize(.mini)
                .frame(width: 74)
                RollingValue(text: "\(Int(preferences.windowGap))", font: .caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
            }
            .help("Gap between tiled windows")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Window gap")
        }
    }

    // MARK: - Layouts

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                title: "Layouts",
                systemImage: "rectangle.3.group",
                tint: Accent.windows,
                trailing: layouts.layouts.isEmpty ? nil : "\(layouts.layouts.count)"
            )

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    saveChip
                    ForEach(layouts.layouts) { layout in
                        LayoutChip(
                            layout: layout,
                            shortcut: shortcut(for: layout),
                            isEnabled: permission.isTrusted,
                            onApply: { layouts.apply(layout) },
                            onDelete: { layouts.delete(layout) }
                        )
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.never)

            if let summary = layouts.lastRestoreSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else if layouts.layouts.isEmpty, !isNamingLayout {
                Text("Arrange your windows, then save the layout to bring it back any time.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .motion(Motion.transition, value: isNamingLayout)
        .motion(Motion.transition, value: layouts.layouts)
        .motion(Motion.snappy, value: layouts.lastRestoreSummary)
    }

    /// "+ Save" flips in place into a name field, so the flow never leaves the chip row.
    @ViewBuilder
    private var saveChip: some View {
        if isNamingLayout {
            HStack(spacing: 5) {
                TextField("Layout name", text: $layoutName)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($isLayoutFieldFocused)
                    .onSubmit(commitLayout)
                    .frame(width: 96)

                Button(action: commitLayout) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(layoutName.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : Accent.windows)
                }
                .buttonStyle(.plain)
                .disabled(layoutName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Save layout")

                Button {
                    isNamingLayout = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .glassEffect(.regular.tint(Accent.windows.opacity(0.2)), in: .rect(cornerRadius: 10))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            Button {
                layouts.clearSummary()
                layoutName = defaultLayoutName()
                isNamingLayout = true
                isLayoutFieldFocused = true
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("Save")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Accent.windows)
                    Text("current setup")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Accent.windows.opacity(0.18)).interactive(), in: .rect(cornerRadius: 10))
            .disabled(!permission.isTrusted)
            .help("Save the position of every open window")
        }
    }

    // MARK: - Helpers

    private func helpText(for action: WindowAction) -> String {
        guard let shortcut = preferences.shortcut(for: .window(action)) else { return action.title }
        return "\(action.title) — \(shortcut.displayString)"
    }

    private func shortcut(for layout: WorkspaceLayout) -> HotKeyCombo? {
        guard let slot = layouts.slot(of: layout) else { return nil }
        return preferences.shortcut(for: .layout(slot))
    }

    private func defaultLayoutName() -> String {
        "Layout \(layouts.layouts.count + 1)"
    }

    private func commitLayout() {
        let name = layoutName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        layouts.capture(name: name)
        isNamingLayout = false
        layoutName = ""
    }

    private func apply(_ action: WindowAction) {
        service.perform(action)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        withMotion(Motion.snappy, reduceMotion: reduceMotion) {
            lastAppliedAction = action
            isPulsing = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withMotion(Motion.fluid, reduceMotion: reduceMotion) { isPulsing = false }
        }
    }
}

// MARK: - Pieces

/// Small glass capsule for the two actions that have no place on the 3×3 map.
private struct ActionPill: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isHovered ? AnyShapeStyle(Accent.windows) : AnyShapeStyle(.primary))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Accent.windows.opacity(isHovered ? 0.24 : 0.1)).interactive(), in: .capsule)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

/// One saved arrangement, applied with a click.
private struct LayoutChip: View {
    let layout: WorkspaceLayout
    let shortcut: HotKeyCombo?
    let isEnabled: Bool
    let onApply: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onApply) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(layout.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let shortcut {
                        Text(shortcut.displayString)
                            .font(.system(size: 8).monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                Text("\(layout.placements.count) windows")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Accent.windows.opacity(isHovered ? 0.22 : 0.08)).interactive(), in: .rect(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 13, height: 13)
                        .background(.red.opacity(0.9), in: .circle)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Delete \(layout.name)")
            }
        }
        .onHover { isHovered = $0 }
        .scaleEffect(isHovered ? 1.03 : 1)
        .motion(Motion.snappy, value: isHovered)
        .disabled(!isEnabled)
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
        .help("Restore \(layout.name)")
        .accessibilityLabel("\(layout.name), \(layout.placements.count) windows")
    }
}

struct AccessibilityPromptCard: View {
    let permission: AccessibilityPermission

    var body: some View {
        GlassCard(tint: .orange) {
            Label("Accessibility access needed", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
                .symbolEffect(.pulse)
            Text("MagicPlus needs permission to move windows and paste for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Grant Access") { permission.request() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                Button("Open Settings") { permission.openSystemSettings() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }
}
