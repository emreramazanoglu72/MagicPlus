//
//  ClipboardService.swift
//  tabmenu
//

import AppKit
import Observation

/// Watches the general pasteboard and keeps a searchable, persisted history.
/// macOS emits no pasteboard change notification, so the change counter is polled.
@Observable
@MainActor
final class ClipboardService {
    private(set) var items: [ClipboardItem] = []

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let storage: ClipboardStorage
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private var pollingTimer: Timer?
    @ObservationIgnored private var lastChangeCount: Int
    /// Set while the app itself writes to the pasteboard, so re-copying does not duplicate entries.
    @ObservationIgnored private var isWritingInternally = false

    private static let pollingInterval: TimeInterval = 0.5
    private static let maximumImageBytes = 10 * 1024 * 1024

    init(
        preferences: Preferences,
        storage: ClipboardStorage = ClipboardStorage(),
        pasteboard: NSPasteboard = .general
    ) {
        self.preferences = preferences
        self.storage = storage
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
        self.items = storage.load()
        storage.pruneImages(keeping: items)
    }

    // MARK: - Lifecycle

    func start() {
        guard pollingTimer == nil else { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureIfChanged() }
        }
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    // MARK: - Queries

    func filtered(by query: String) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.searchText.localizedCaseInsensitiveContains(trimmed) }
    }

    func image(for item: ClipboardItem) -> NSImage? {
        guard case .image(let fileName, _) = item.content else { return nil }
        return storage.image(named: fileName)
    }

    // MARK: - Mutations

    func copyToPasteboard(_ item: ClipboardItem, asPlainText: Bool = false) {
        isWritingInternally = true
        pasteboard.clearContents()

        switch item.content {
        case .text(let value):
            pasteboard.setString(value, forType: .string)
        case .fileURLs(let urls):
            if asPlainText {
                pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            } else {
                pasteboard.writeObjects(urls as [NSURL])
            }
        case .image(let fileName, _):
            if let data = storage.imageData(named: fileName) {
                pasteboard.setData(data, forType: .png)
            }
        }

        lastChangeCount = pasteboard.changeCount
        moveToFront(item)
        isWritingInternally = false
    }

    /// Writes a rewritten version of a text entry, leaving history untouched: the transform
    /// is a paste-time choice, not an edit of what was copied.
    func copyTransformed(_ item: ClipboardItem, using transform: ClipboardTransform) {
        guard let text = item.plainText, let rewritten = transform.apply(to: text) else { return }
        isWritingInternally = true
        pasteboard.clearContents()
        pasteboard.setString(rewritten, forType: .string)
        lastChangeCount = pasteboard.changeCount
        isWritingInternally = false
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        sortByPinning()
        persist()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        storage.pruneImages(keeping: items)
        persist()
    }

    func clearHistory(includingPinned: Bool = false) {
        items = includingPinned ? [] : items.filter(\.isPinned)
        storage.pruneImages(keeping: items)
        persist()
    }

    // MARK: - Capture

    private func captureIfChanged() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        // The change is consumed before any gate: content copied while capture is disabled
        // must never be recorded retroactively once history is re-enabled.
        lastChangeCount = pasteboard.changeCount

        guard preferences.isClipboardEnabled, !isWritingInternally else { return }
        guard !isConcealed else { return }
        let source = NSWorkspace.shared.frontmostApplication
        if let bundleID = source?.bundleIdentifier, preferences.ignoredBundleIDs.contains(bundleID) { return }
        guard let pending = readContent() else { return }

        // Secrets stay pasteable but never enter the persisted history.
        if preferences.skipsSensitiveContent,
           case .text(let text) = pending,
           SensitiveContentDetector.looksSensitive(text) {
            return
        }

        guard let content = persisted(pending) else { return }

        let item = ClipboardItem(
            content: content,
            sourceBundleID: source?.bundleIdentifier,
            sourceAppName: source?.localizedName
        )
        insert(item)
    }

    /// Password managers mark their payloads as concealed; those are never recorded.
    private var isConcealed: Bool {
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let types = pasteboard.types ?? []
        return types.contains(concealedType) || types.contains(transientType)
    }

    /// Pasteboard content as read, before anything is persisted. Image bytes stay in memory
    /// so a capture dropped by a later gate never leaves a file behind.
    private enum PendingContent {
        case text(String)
        case fileURLs([URL])
        case image(data: Data, pixelSize: CGSize)
    }

    private func readContent() -> PendingContent? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .fileURLs(urls)
        }

        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(string)
        }

        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return imageContent(from: data)
        }

        return nil
    }

    private func imageContent(from data: Data) -> PendingContent? {
        guard let image = NSImage(data: data),
              let representation = image.representations.first,
              let pngData = pngRepresentation(of: image) ?? (data.count <= Self.maximumImageBytes ? data : nil),
              pngData.count <= Self.maximumImageBytes
        else { return nil }

        let size = CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        return .image(data: pngData, pixelSize: size)
    }

    /// Touches disk only once every gate has passed, so nothing dropped is ever persisted.
    private func persisted(_ pending: PendingContent) -> ClipboardItem.Content? {
        switch pending {
        case .text(let value):
            return .text(value)
        case .fileURLs(let urls):
            return .fileURLs(urls)
        case .image(let data, let pixelSize):
            guard let fileName = storage.writeImage(data) else { return nil }
            return .image(fileName: fileName, pixelSize: pixelSize)
        }
    }

    private func pngRepresentation(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - History bookkeeping

    private func insert(_ item: ClipboardItem) {
        if let existingIndex = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            var existing = items.remove(at: existingIndex)
            existing = ClipboardItem(
                id: existing.id,
                createdAt: item.createdAt,
                content: existing.content,
                sourceBundleID: item.sourceBundleID,
                sourceAppName: item.sourceAppName,
                isPinned: existing.isPinned
            )
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
        }

        enforceHistoryLimit()
        sortByPinning()
        persist()
    }

    private func moveToFront(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index != 0 else { return }
        let moved = items.remove(at: index)
        items.insert(moved, at: 0)
        sortByPinning()
        persist()
    }

    /// Pinned entries always stay on top; the rest keep their recency order.
    private func sortByPinning() {
        items.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func enforceHistoryLimit() {
        let limit = max(10, preferences.historyLimit)
        let unpinnedCount = items.count(where: { !$0.isPinned })
        guard unpinnedCount > limit else { return }

        var remaining = unpinnedCount - limit
        for index in items.indices.reversed() where remaining > 0 {
            guard !items[index].isPinned else { continue }
            items.remove(at: index)
            remaining -= 1
        }
        storage.pruneImages(keeping: items)
    }

    private func persist() {
        storage.save(items)
    }
}
