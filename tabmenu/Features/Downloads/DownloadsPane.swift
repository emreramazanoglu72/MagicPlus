//
//  DownloadsPane.swift
//  tabmenu
//

import SwiftUI

/// The queue, inside the island. Everything in flight, newest first, each row with the one
/// control that matters for the state it is in.
struct DownloadsPane: View {
    let model: NotchModel
    /// Opens the prompt with an address field. The queue is also where someone looks when
    /// nothing was detected at all.
    var onAddLink: (() -> Void)?

    private var store: DownloadStore { model.downloads }

    var body: some View {
        if store.items.isEmpty {
            IslandEmptyState(
                systemImage: "arrow.down.circle",
                title: "Nothing downloading",
                message: "Copy a link and the island offers to fetch it. Dropping one here works too."
            ) {
                IslandChipButton(title: "Paste a link", isProminent: true) {
                    onAddLink?()
                }
            }
        } else {
            VStack(spacing: Island.Space.xs) {
                if store.hasActivity { summary }

                ScrollView(.vertical) {
                    VStack(spacing: Island.Space.xs) {
                        ForEach(store.items) { item in
                            DownloadRow(item: item, store: store)
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// One line for the whole queue, so the pane answers "how long" without arithmetic.
    private var summary: some View {
        HStack(spacing: Island.Space.s) {
            IslandProgressRing(value: store.overallProgress, diameter: 12)

            Text(String(localized: "\(store.activeItems.count) active", comment: "Downloads in flight"))
                .font(Island.Text.caption)
                .foregroundStyle(Island.Ink.secondary)

            Spacer(minLength: 0)

            if store.totalSpeed > 0 {
                Text(Format.speed(store.totalSpeed))
                    .font(Island.Text.numericSmall)
                    .foregroundStyle(Island.Ink.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, Island.Space.s)
        .padding(.bottom, Island.Space.hair)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let store: DownloadStore

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Island.Space.s) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(Island.Text.label)
                    .foregroundStyle(Island.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.state == .running || item.state == .paused || item.state == .waiting {
                    LevelBar(value: item.progress ?? 0, tint: tint, height: 3)
                        .opacity(item.progress == nil ? 0.35 : 1)
                }

                Text(item.statusLine)
                    .font(Island.Text.caption)
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            IslandIconButton(systemImage: actionSymbol, help: actionHelp, size: 24) {
                store.toggle(item.id)
            }

            if isHovered {
                IslandIconButton(systemImage: "xmark", help: String(localized: "Remove from the list", comment: "Download control"), size: 24) {
                    store.remove(item.id)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, Island.Space.s)
        .padding(.vertical, Island.Space.s)
        .background(
            isHovered ? Island.Fill.regular : Island.Fill.subtle,
            in: .rect(cornerRadius: Island.Radius.card, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .contextMenu {
            if item.state == .completed {
                Button("Open") { store.open(item) }
            }
            Button("Reveal in Finder") { store.revealInFinder(item) }
            Button("Copy link") { store.copyLink(item) }
            Divider()
            Button("Remove", role: .destructive) { store.remove(item.id) }
        }
        .help(item.url.absoluteString)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.fileName), \(item.statusLine)")
    }

    private var statusTint: Color {
        switch item.state {
        case .failed: Island.Signal.danger
        case .waiting: Island.Signal.warning
        default: Island.Ink.tertiary
        }
    }

    private var tint: Color {
        switch item.state {
        case .completed: Island.Signal.success
        case .failed: Island.Signal.danger
        case .paused: Island.Ink.tertiary
        // Interrupted, not broken: it is picking itself up.
        case .waiting: Island.Signal.warning
        case .running, .queued: Island.Signal.info
        }
    }

    private var actionSymbol: String {
        switch item.state {
        case .running, .queued: "pause.fill"
        case .paused: "play.fill"
        case .waiting: "arrow.clockwise"
        case .failed: "arrow.clockwise"
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
