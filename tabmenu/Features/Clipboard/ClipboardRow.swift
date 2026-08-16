//
//  ClipboardRow.swift
//  tabmenu
//

import SwiftUI

extension ClipboardItem {
    /// Content-type colour used by the badge and the preview pane.
    var accent: Color {
        switch content {
        case .text(let value):
            URL(string: value)?.scheme?.hasPrefix("http") == true ? .indigo : .blue
        case .fileURLs: .orange
        case .image: .pink
        }
    }
}

/// Shared row presentation for both the popover list and the floating panel.
struct ClipboardRow: View {
    let item: ClipboardItem
    let thumbnail: NSImage?
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            badge

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .rotationEffect(.degrees(45))
                    .accessibilityLabel("Pinned")
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var badge: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(.rect(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(.white.opacity(0.15))
                }
        } else {
            Image(systemName: item.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.accent)
                .frame(width: 28, height: 28)
                .background(item.accent.opacity(0.16), in: .rect(cornerRadius: 7))
        }
    }

    private var subtitle: String {
        [item.sourceAppName, item.detail, Format.relativeTime(item.createdAt)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
