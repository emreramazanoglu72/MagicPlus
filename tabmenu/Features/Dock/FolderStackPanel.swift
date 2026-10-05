//
//  FolderStackPanel.swift
//  MagicPlus
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// What a pinned folder shows when it is clicked.
///
/// Clicking one used to open the Finder, which is what happens when a dock has nowhere to put the
/// answer. A folder in the Dock is a shortcut to what is *in* it, so this is what is in it: newest
/// first, because a folder pinned to a dock is almost always somewhere things arrive — Downloads
/// being the one everybody has.
///
/// Reading is done off the main thread and only when the panel opens. A folder can hold thousands of
/// entries, and a dock that stutters when a folder is clicked is a dock that gets clicked once.
@MainActor
final class FolderStackPanel: NSObject, NSWindowDelegate {
    @Observable
    @MainActor
    final class Model {
        var title = ""
        var entries: [Entry] = []
        var isLoading = false
        /// The folder itself, for the button that hands the whole thing to the Finder.
        var folder: URL?
        var style = DockStyle()

        struct Entry: Identifiable, Equatable {
            let url: URL
            let isDirectory: Bool
            var id: URL { url }
            var name: String { url.lastPathComponent }
        }
    }

    private let model = Model()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let outsideClicks = OutsideClickMonitor()

    private static let size = CGSize(width: 460, height: 420)
    /// Enough to be useful, few enough that the panel opens at once. A folder with more than this
    /// in it is a folder somebody opens in the Finder.
    nonisolated static let entryLimit = 60

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(folder: URL, anchor: CGRect, style: DockStyle) {
        if isVisible, model.folder == folder {
            hide()
        } else {
            show(folder: folder, anchor: anchor, style: style)
        }
    }

    func show(folder: URL, anchor: CGRect, style: DockStyle) {
        model.folder = folder
        model.title = folder.lastPathComponent
        model.style = style
        model.entries = []
        model.isLoading = true

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, anchor: anchor, edge: style.edge)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyMonitor()
        outsideClicks.start(panel: panel, anchor: anchor) { [weak self] in self?.hide() }

        Task { [weak self] in
            let entries = await Self.read(folder)
            // The panel may have moved on to another folder while this was in flight.
            guard let self, model.folder == folder else { return }
            model.entries = entries
            model.isLoading = false
        }
    }

    func hide() {
        stopKeyMonitor()
        outsideClicks.stop()
        panel?.orderOut(nil)
    }

    // MARK: - Reading

    /// The folder's contents, newest first, off the main thread.
    nonisolated static func read(_ folder: URL) async -> [Model.Entry] {
        await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isHiddenKey]
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return [] }

            return contents
                .map { url -> (Model.Entry, Date) in
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    return (
                        Model.Entry(url: url, isDirectory: values?.isDirectory ?? false),
                        values?.contentModificationDate ?? .distantPast
                    )
                }
                .sorted { $0.1 > $1.1 }
                .prefix(entryLimit)
                .map(\.0)
        }.value
    }

    // MARK: - Placement

    private func position(_ panel: NSPanel, anchor: CGRect, edge: DockStyle.Edge) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        else { return }
        let gap: CGFloat = 8
        var origin: CGPoint = switch edge {
        case .bottom: CGPoint(x: anchor.midX - Self.size.width / 2, y: anchor.maxY + gap)
        case .top: CGPoint(x: anchor.midX - Self.size.width / 2, y: anchor.minY - Self.size.height - gap)
        }
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - Self.size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FolderStackView(
            model: model,
            onOpen: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.hide()
            },
            onOpenFolder: { [weak self] in
                guard let folder = self?.model.folder else { return }
                NSWorkspace.shared.open(folder)
                self?.hide()
            }
        ))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard let self, isVisible, Int(event.keyCode) == kVK_Escape else { return event }
            hide()
            return nil
        })
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// The grid a pinned folder opens into.
private struct FolderStackView: View {
    let model: FolderStackPanel.Model
    var onOpen: (URL) -> Void
    var onOpenFolder: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
    private var style: DockStyle { model.style }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill((style.tint ?? .black).opacity(min(1, style.backgroundOpacity + 0.2)))
            }
        }
        .environment(\.colorScheme, style.contentScheme ?? .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            Button(action: onOpenFolder) {
                Text("Open in Finder", comment: "Folder stack: hand the whole folder over")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.14))
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("This folder is empty", comment: "Folder stack: nothing in it")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(model.entries) { entry in
                        FolderEntryTile(entry: entry) { onOpen(entry.url) }
                    }
                }
                .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// One thing in the folder.
private struct FolderEntryTile: View {
    let entry: FolderStackPanel.Model.Entry
    var onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                Text(entry.name)
                    .font(.system(size: 10.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 26, alignment: .top)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(0.10))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .help(entry.url.path)
        .accessibilityLabel(entry.name)
    }
}
