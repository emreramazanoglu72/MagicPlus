//
//  DownloadsCard.swift
//  tabmenu
//

import SwiftUI

/// The queue, in the menu bar popover.
///
/// The island is where a download announces itself, but the island is optional — switch the notch
/// panel off and the queue had nowhere left to live. A download that cannot be found is a download
/// that cannot be paused, retried or explained, so it belongs somewhere that does not depend on a
/// surface the user may have turned off.
struct DownloadsCard: View {
    let store: DownloadStore
    /// Opens the prompt with an address field.
    var onAddLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            summary

            if store.items.isEmpty {
                GlassCard(tint: Accent.network) {
                    Text("Nothing downloading")
                        .font(.callout.weight(.medium))
                    Text("Copy a link and MagicPlus offers to fetch it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(store.items.prefix(8)) { item in
                    DownloadCardRow(item: item, store: store)
                }
                if store.items.count > 8 {
                    Text("\(store.items.count - 8) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                }
            }
        }
    }

    private var summary: some View {
        HStack(spacing: Metrics.tightSpacing) {
            SectionHeader(
                title: String(localized: "Downloads", comment: "Popover section"),
                systemImage: "arrow.down.circle",
                tint: Accent.network,
                trailing: store.totalSpeed > 0 ? Format.speed(store.totalSpeed) : nil
            )

            Button {
                onAddLink()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Paste a link")

            if store.items.contains(where: \.state.isFinished) {
                Button {
                    store.clearFinished()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear finished downloads")
            }
        }
    }
}

private struct DownloadCardRow: View {
    let item: DownloadItem
    let store: DownloadStore

    var body: some View {
        GlassCard(tint: tint, spacing: 5) {
            HStack(spacing: Metrics.tightSpacing) {
                Image(systemName: item.kind.symbolName)
                    .font(.caption)
                    .foregroundStyle(tint)

                Text(item.fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Button {
                    store.toggle(item.id)
                } label: {
                    Image(systemName: actionSymbol)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(actionHelp)

                Button {
                    store.remove(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Remove from the list")
            }

            if item.state == .running || item.state == .paused || item.state == .waiting {
                ProgressView(value: item.progress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .opacity(item.progress == nil ? 0.4 : 1)
            }

            Text(item.statusLine)
                .font(.caption)
                .foregroundStyle(item.state == .failed ? .orange : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contextMenu {
            if item.state == .completed {
                Button("Open") { store.open(item) }
            }
            Button("Reveal in Finder") { store.revealInFinder(item) }
            Button("Copy link") { store.copyLink(item) }
            Divider()
            Button("Remove", role: .destructive) { store.remove(item.id) }
        }
    }

    private var tint: Color {
        switch item.state {
        case .completed: .green
        case .failed: .orange
        case .waiting: .yellow
        case .paused: .secondary
        case .running, .queued: Accent.network
        }
    }

    private var actionSymbol: String {
        switch item.state {
        case .running, .queued: "pause.fill"
        case .paused: "play.fill"
        case .waiting, .failed: "arrow.clockwise"
        case .completed: "folder"
        }
    }

    private var actionHelp: String {
        switch item.state {
        case .running, .queued: String(localized: "Pause", comment: "Download control")
        case .paused: String(localized: "Resume", comment: "Download control")
        case .waiting: String(localized: "Try again now", comment: "Download control")
        case .failed: String(localized: "Try again", comment: "Download control")
        case .completed: String(localized: "Open", comment: "Download control")
        }
    }
}
