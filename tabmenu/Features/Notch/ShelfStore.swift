//
//  ShelfStore.swift
//  tabmenu
//

import AppKit
import Observation
import os

struct ShelfFile: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    let addedAt: Date

    init(url: URL, id: UUID = UUID(), addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
    }

    var name: String { url.lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

/// Temporary drop zone for files, held across launches. Entries whose files have moved or
/// been deleted are dropped on load.
@Observable
@MainActor
final class ShelfStore {
    private(set) var files: [ShelfFile] = []

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Shelf")
    @ObservationIgnored private let storageURL: URL

    private static let limit = 30

    init() {
        storageURL = AppSupportDirectory.url().appendingPathComponent("shelf.json")
        load()
    }

    var urls: [URL] { files.map(\.url) }

    // MARK: - Mutations

    func add(_ incoming: [URL]) {
        let existing = Set(files.map(\.url.standardizedFileURL))
        let additions = incoming
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0) && FileManager.default.fileExists(atPath: $0.path) }
            .map { ShelfFile(url: $0) }

        guard !additions.isEmpty else { return }
        files.insert(contentsOf: additions, at: 0)
        if files.count > Self.limit { files.removeLast(files.count - Self.limit) }
        save()
    }

    func remove(_ file: ShelfFile) {
        files.removeAll { $0.id == file.id }
        save()
    }

    func clear() {
        files.removeAll()
        save()
    }

    // MARK: - Finder actions

    func open(_ file: ShelfFile) {
        NSWorkspace.shared.open(file.url)
    }

    func revealInFinder(_ file: ShelfFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let stored = try? JSONDecoder().decode([ShelfFile].self, from: data)
        else { return }
        files = stored.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if files.count != stored.count { save() }
    }

    private func save() {
        do {
            try JSONEncoder().encode(files).write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Failed to save shelf: \(error.localizedDescription, privacy: .public)")
        }
    }
}
