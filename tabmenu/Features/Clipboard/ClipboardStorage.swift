//
//  ClipboardStorage.swift
//  tabmenu
//

import AppKit
import os

/// Persists clipboard history to Application Support. Text and file entries live in a single
/// JSON document; image payloads are written as separate files to keep that document small.
nonisolated struct ClipboardStorage {
    private let logger = Logger(subsystem: "com.tabmenu", category: "ClipboardStorage")
    private let fileManager = FileManager.default
    private let directory: URL
    private let historyURL: URL
    private let imagesDirectory: URL

    init() {
        directory = AppSupportDirectory.url()
        historyURL = directory.appendingPathComponent("clipboard-history.json")
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        createDirectoriesIfNeeded()
    }

    // MARK: - History

    func load() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        do {
            return try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            logger.error("Unreadable history, starting empty: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func save(_ items: [ClipboardItem]) {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: historyURL, options: .atomic)
            // History holds whatever the user copied; the atomic write recreates the file,
            // so the owner-only mode is re-applied every time.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch {
            logger.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Images

    func writeImage(_ data: Data) -> String? {
        let fileName = "\(UUID().uuidString).png"
        let url = imagesDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return fileName
        } catch {
            logger.error("Failed to store image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func image(named fileName: String) -> NSImage? {
        NSImage(contentsOf: imagesDirectory.appendingPathComponent(fileName))
    }

    func imageData(named fileName: String) -> Data? {
        try? Data(contentsOf: imagesDirectory.appendingPathComponent(fileName))
    }

    /// Removes image files no longer referenced by history, keeping disk usage bounded.
    func pruneImages(keeping items: [ClipboardItem]) {
        let referenced = Set(items.compactMap { item -> String? in
            if case .image(let fileName, _) = item.content { return fileName }
            return nil
        })
        guard let stored = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        for fileName in stored where !referenced.contains(fileName) {
            try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(fileName))
        }
    }

    private func createDirectoriesIfNeeded() {
        for url in [directory, imagesDirectory] {
            try? fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
