//
//  ClipboardPreviewPane.swift
//  tabmenu
//

import SwiftUI

/// Detail side of the clipboard panel: full content of the highlighted entry plus its actions.
struct ClipboardPreviewPane: View {
    let item: ClipboardItem?
    let image: NSImage?
    var transforms: [ClipboardTransform] = []
    let onPaste: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    var onTransform: (ClipboardTransform) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item {
                header(for: item)
                body(for: item)
                Spacer(minLength: 0)
                if !transforms.isEmpty { transformRow }
                actions(for: item)
            } else {
                placeholder
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(for item: ClipboardItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.symbolName)
                .font(.caption)
                .foregroundStyle(item.accent)
            Text(item.sourceAppName ?? "Unknown app")
                .font(.caption.weight(.medium))
            Spacer()
            Text(Format.relativeTime(item.createdAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func body(for item: ClipboardItem) -> some View {
        switch item.content {
        case .text(let value):
            ScrollView {
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))

        case .fileURLs(let urls):
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(urls, id: \.self) { url in
                        HStack(spacing: 7) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))

        case .image(_, let size):
            VStack(spacing: 6) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(.rect(cornerRadius: 10))
                }
                Text("\(Int(size.width)) × \(Int(size.height)) px")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Paste-time rewrites. Only transforms that would change this entry are offered, so the
    /// row never shows a button that does nothing.
    private var transformRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(transforms) { transform in
                    Button {
                        onTransform(transform)
                    } label: {
                        Label(transform.title, systemImage: transform.symbolName)
                            .font(.caption)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Paste with this change applied")
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
    }

    private func actions(for item: ClipboardItem) -> some View {
        HStack(spacing: 6) {
            Button(action: onPaste) {
                Label("Paste", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)

            Button(action: onTogglePin) {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Delete this item")
            .accessibilityLabel("Delete item")
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(Accent.clipboard.opacity(0.7))
                .symbolEffect(.pulse)
            Text("Select an item to preview it")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
