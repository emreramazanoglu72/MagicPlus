//
//  ScreenshotWatcher.swift
//  tabmenu
//

import Foundation
import os

/// Notices new screenshots so they can drop straight onto the shelf.
///
/// Spotlight is asked for files flagged `kMDItemIsScreenCapture` rather than watching a
/// folder, so this keeps working wherever the user has pointed `screencapture` — Desktop,
/// Downloads, or somewhere custom.
@MainActor
final class ScreenshotWatcher {
    var onNewScreenshot: ((URL) -> Void)?

    private let logger = Logger(subsystem: "com.tabmenu", category: "Screenshots")
    private let query = NSMetadataQuery()
    private var startedAt = Date.distantFuture
    private var seenPaths: Set<String> = []

    /// Shots older than this at start-up are history, not something that just happened.
    private static let recencyWindow: TimeInterval = 5

    var isRunning: Bool { query.isStarted }

    func start() {
        guard !query.isStarted else { return }

        startedAt = Date()
        seenPaths.removeAll()

        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture = 1")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: kMDItemContentCreationDate as String, ascending: false)]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInitialGather),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )

        query.start()
    }

    func stop() {
        guard query.isStarted else { return }
        query.stop()
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The first pass returns every screenshot ever taken; those are recorded as seen so only
    /// genuinely new ones are reported afterwards.
    @objc private func handleInitialGather(_ notification: Notification) {
        query.disableUpdates()
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: kMDItemPath as String) as? String
            else { continue }
            seenPaths.insert(path)
        }
        query.enableUpdates()
        logger.notice("screenshot watcher ready, \(self.seenPaths.count) existing shots ignored")
    }

    @objc private func handleUpdate(_ notification: Notification) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: kMDItemPath as String) as? String,
                  !seenPaths.contains(path)
            else { continue }

            seenPaths.insert(path)

            // Spotlight can surface an older file late; only react to fresh captures.
            let created = item.value(forAttribute: kMDItemContentCreationDate as String) as? Date
            let isFresh = created.map { $0 > startedAt.addingTimeInterval(-Self.recencyWindow) } ?? true
            guard isFresh, FileManager.default.fileExists(atPath: path) else { continue }

            logger.notice("new screenshot detected")
            onNewScreenshot?(URL(fileURLWithPath: path))
        }
    }
}
