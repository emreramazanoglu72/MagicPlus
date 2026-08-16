//
//  DockPreviewView.swift
//  tabmenu
//

import SwiftUI

/// Horizontal strip of live window previews shown above a hovered Dock icon.
struct DockPreviewView: View {
    let model: DockPreviewModel
    /// Read live so the thumbnails toggle in Settings applies to the cached panel.
    let preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.windows) { window in
                        WindowPreviewCard(
                            window: window,
                            thumbnail: model.thumbnail(for: window),
                            showsThumbnail: preferences.showsWindowThumbnails,
                            onSelect: { model.focus(window) },
                            onClose: { model.close(window) },
                            onMinimize: { model.minimize(window) }
                        )
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThickMaterial, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.12))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.applicationName)
                .font(.caption.weight(.semibold))
            Text("\(model.windows.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: .capsule)

            Spacer()

            Button(action: model.quitApplication) {
                Label("Quit", systemImage: "power")
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit \(model.applicationName)")
        }
    }
}

private struct WindowPreviewCard: View {
    let window: SwitchableWindow
    let thumbnail: NSImage?
    let showsThumbnail: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void

    @State private var isHovered = false

    private static let cardWidth: CGFloat = 176

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                preview
                Text(window.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Self.cardWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .accessibilityLabel(window.title)
        .accessibilityHint("Switch to this window")
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let thumbnail, showsThumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
            .frame(width: Self.cardWidth, height: 110)
            .clipShape(.rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isHovered ? Accent.windows : .white.opacity(0.12), lineWidth: isHovered ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(isHovered ? 0.35 : 0.18), radius: isHovered ? 8 : 4, y: 2)

            if isHovered {
                controls
                    .padding(5)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
            }

            if window.isMinimized {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption2)
                    .padding(4)
                    .background(.black.opacity(0.5), in: .circle)
                    .foregroundStyle(.white)
                    .padding(5)
                    .frame(width: Self.cardWidth, height: 110, alignment: .bottomTrailing)
                    .accessibilityHidden(true)
            }
        }
        .scaleEffect(isHovered ? 1.02 : 1)
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            if let icon = window.applicationIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .opacity(0.85)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            CardControl(systemImage: "xmark", tint: .red, help: "Close window", action: onClose)
            CardControl(systemImage: "minus", tint: .yellow, help: "Minimise window", action: onMinimize)
        }
    }
}

private struct CardControl: View {
    let systemImage: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black.opacity(0.7))
                .frame(width: 16, height: 16)
                .background(tint, in: .circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
