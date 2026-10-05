//
//  DownloadWatcher.swift
//  tabmenu
//

import Foundation
import os

/// Notices files arriving in Downloads — AirDrop, browser downloads, anything — so the notch
/// can say so and park them on the shelf.
///
/// Partial files (`.download`, `.crdownload`, `.part`) are ignored until the real file lands,
/// otherwise every download would announce itself twice.
@MainActor
final class DownloadWatcher {
    var onNewDownload: ((URL) -> Void)?

    private let logger = Logger(subsystem: "com.tabmenu", category: "Downloads")
    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var knownNames: Set<String> = []
    private var settleTask: Task<Void, Never>?

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "tmp"]
    /// Downloads land in bursts; waiting lets a file finish before it is announced.
    private static let settleDelay: Duration = .milliseconds(700)

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    var isRunning: Bool { source != nil }

    /// Marks a name as already accounted for, so a file this app is about to write itself is
    /// not announced a second time as an arrival from somewhere else.
    func claim(_ name: String) {
        knownNames.insert(name)
    }

    func start() {
        guard source == nil else { return }

        knownNames = currentNames()
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            logger.error("cannot watch \(self.directory.path, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        settleTask?.cancel()
        settleTask = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit {
        source?.cancel()
    }

    private func scheduleScan() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    private func scan() {
        let names = currentNames()
        defer { knownNames = names }

        for name in names.subtracting(knownNames) {
            let url = directory.appendingPathComponent(name)
            guard !Self.partialExtensions.contains(url.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: url.path)
            else { continue }

            logger.notice("new download detected")
            onNewDownload?(url)
        }
    }

    private func currentNames() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(contents.filter { !$0.hasPrefix(".") })
    }
}
