//
//  MediaDownloadRunner.swift
//  tabmenu
//

import Foundation
import os

/// Runs the media helper for one download and turns its output into the same events the HTTP
/// engine emits, so the queue and the island never need to know which of the two is working.
///
/// Pausing terminates the helper and keeps its partial file; resuming starts it again with
/// `--continue`, which picks up where it stopped. That is the whole of the pause support the
/// helper offers, and it behaves exactly like the byte-offset resume on the HTTP side.
nonisolated final class MediaDownloadRunner: @unchecked Sendable {
    private static let progressPrefix = "MP-PROGRESS"
    private static let filePrefix = "MP-FILE"

    private let logger = Logger(subsystem: "com.tabmenu", category: "Downloads")
    private let onEvent: @Sendable (DownloadEvent) -> Void
    /// Guards the two tables below, which are read from the process queue and written from
    /// the queue controller.
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var pausing: Set<UUID> = []

    init(onEvent: @escaping @Sendable (DownloadEvent) -> Void) {
        self.onEvent = onEvent
    }

    // MARK: - Control

    /// The whole contract with the helper, in one place so it can be checked without running
    /// anything.
    static func arguments(
        url: URL,
        quality: MediaQuality,
        folder: URL,
        canMerge: Bool,
        cookies: MediaCookieSource
    ) -> [String] {
        var arguments = [
            "--no-playlist",
            "--continue",
            "--no-color",
            "--newline",
            // `--print` below implies `--quiet`, which silences progress entirely. This puts
            // it back; without it a download reports nothing at all until it finishes.
            "--progress",
            "--no-warnings",
            "--format", quality.selector(canMerge: canMerge),
            "--paths", folder.path,
            // Titles can be longer than a file name may be; 150 bytes leaves room for the
            // identifier and the extension. Names are not restricted to ASCII — a Turkish or
            // Japanese title stays legible, and APFS has no trouble with either.
            "--output", "%(title).150B [%(id)s].%(ext)s",
            "--progress-template",
            "download:\(progressPrefix) %(progress.downloaded_bytes)s %(progress.total_bytes)s "
                + "%(progress.total_bytes_estimate)s %(progress.speed)s",
            "--print", "after_move:\(filePrefix) %(filepath)s"
        ]
        if let browser = cookies.helperName {
            arguments += ["--cookies-from-browser", browser]
        }
        arguments.append(url.absoluteString)
        return arguments
    }

    func start(
        id: UUID,
        url: URL,
        quality: MediaQuality,
        folder: URL,
        tool: URL,
        cookies: MediaCookieSource
    ) {
        let canMerge = MediaTool.hasMerger()
        let process = Process()
        process.executableURL = tool
        process.environment = MediaTool.environment()
        process.arguments = Self.arguments(
            url: url,
            quality: quality,
            folder: folder,
            canMerge: canMerge,
            cookies: cookies
        )

        let pipe = Pipe()
        process.standardOutput = pipe
        // Both streams into one pipe: progress and the reason a download failed arrive on
        // different ones depending on the helper's version.
        process.standardError = pipe

        lock.withLock {
            processes[id] = process
            pausing.remove(id)
        }

        Task.detached(priority: .utility) { [weak self] in
            await self?.pump(
                id: id,
                process: process,
                pipe: pipe,
                canMerge: canMerge,
                usesCookies: cookies != .none
            )
        }
    }

    /// Stops the helper but keeps what it has written. No event follows — the caller has
    /// already recorded the pause.
    func pause(id: UUID) {
        let process: Process? = lock.withLock {
            pausing.insert(id)
            return processes[id]
        }
        process?.terminate()
    }

    func isRunning(id: UUID) -> Bool {
        lock.withLock { processes[id]?.isRunning ?? false }
    }

    // MARK: - Output

    private func pump(
        id: UUID,
        process: Process,
        pipe: Pipe,
        canMerge: Bool,
        usesCookies: Bool
    ) async {
        do {
            try process.run()
        } catch {
            finish(id: id, event: .failed(id: id, reason: error.localizedDescription, isTransient: false))
            return
        }

        // The parent's copy of the write end has to go, or the reader never sees the end of
        // the stream after the helper exits.
        try? pipe.fileHandleForWriting.close()

        var accumulator = ProgressAccumulator()
        var received: Int64 = 0
        var announcedStart = false
        var lastMessage: String?

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if line.hasPrefix(Self.progressPrefix) {
                    guard let sample = Self.parseProgress(line) else { continue }
                    let progress = accumulator.push(sample)
                    received = progress.received

                    if !announcedStart {
                        announcedStart = true
                        onEvent(.started(
                            id: id,
                            totalBytes: progress.total,
                            receivedBytes: progress.received,
                            isResumable: true
                        ))
                    }
                    onEvent(.progress(
                        id: id,
                        receivedBytes: progress.received,
                        bytesPerSecond: sample.speed ?? 0
                    ))
                    if let total = progress.total {
                        onEvent(.resized(id: id, totalBytes: total))
                    }
                } else if line.hasPrefix(Self.filePrefix) {
                    let path = String(line.dropFirst(Self.filePrefix.count)).trimmingCharacters(in: .whitespaces)
                    guard !path.isEmpty else { continue }
                    onEvent(.named(id: id, fileName: URL(fileURLWithPath: path).lastPathComponent))
                } else {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { lastMessage = trimmed }
                }
            }
        } catch {
            logger.error("media output ended: \(error.localizedDescription, privacy: .public)")
        }

        process.waitUntilExit()

        let wasPausing = lock.withLock { pausing.contains(id) }
        if wasPausing {
            finish(id: id, event: nil)
            return
        }
        guard process.terminationStatus == 0 else {
            finish(id: id, event: .failed(
                id: id,
                reason: Self.reason(
                    from: lastMessage,
                    status: process.terminationStatus,
                    canMerge: canMerge,
                    usesCookies: usesCookies
                ),
                isTransient: false
            ))
            return
        }
        finish(id: id, event: .finished(id: id, receivedBytes: received))
    }

    private func finish(id: UUID, event: DownloadEvent?) {
        lock.withLock {
            processes[id] = nil
            pausing.remove(id)
        }
        if let event { onEvent(event) }
    }

    // MARK: - Parsing

    struct ProgressSample {
        let received: Int64
        let total: Int64?
        let speed: Double?
    }

    /// Adds up a download that arrives as more than one stream.
    ///
    /// A video and its audio are two separate transfers, and the helper counts each from zero.
    /// Reported raw, the progress bar would fill, snap back to nothing and fill again — so the
    /// finished streams are carried forward and the total grows as each one announces itself.
    struct ProgressAccumulator {
        private var completedBytes: Int64 = 0
        private var completedTotal: Int64 = 0
        private var streamBytes: Int64 = 0
        private var streamTotal: Int64?

        /// - Returns: bytes so far across every stream, and the total where it is known.
        mutating func push(_ sample: ProgressSample) -> (received: Int64, total: Int64?) {
            // A count that went backwards means the previous stream finished and a new one
            // started; nothing else can make it drop.
            if sample.received < streamBytes {
                completedBytes += streamBytes
                completedTotal += streamTotal ?? streamBytes
            }
            streamBytes = sample.received
            streamTotal = sample.total

            let received = completedBytes + sample.received
            guard let total = sample.total else { return (received, nil) }
            return (received, completedTotal + total)
        }
    }

    /// `MP-PROGRESS 1048576 20971520 NA 524288.0` — the helper prints `NA` for anything it
    /// does not know yet, which is most fields on the first line.
    static func parseProgress(_ line: String) -> ProgressSample? {
        let fields = line.split(separator: " ").dropFirst().map(String.init)
        guard fields.count >= 4, let received = Int64(fields[0]) else { return nil }
        return ProgressSample(
            received: received,
            total: Int64(fields[1]) ?? Int64(Double(fields[2]) ?? 0).nonZero,
            speed: Double(fields[3])
        )
    }

    /// The helper's own last word where there is one — it explains a private video or a
    /// geo-block far better than an exit code can.
    static func reason(
        from message: String?,
        status: Int32,
        canMerge: Bool,
        usesCookies: Bool
    ) -> String {
        if let message, message.lowercased().contains("error") {
            let cleaned = message
                .replacingOccurrences(of: "ERROR: ", with: "")
                .replacingOccurrences(of: "\u{1B}[0;31m", with: "")

            // "HTTP Error 403" after a few megabytes is the site refusing a stream URL it just
            // handed out, and the helper's own words say nothing a user could act on. Both
            // answers are settings away, so the message names the one that applies.
            if cleaned.contains("403") {
                if !usesCookies {
                    return String(
                        localized: "The site blocked the download partway — turn on browser cookies in Settings",
                        comment: "Download failure from a media site that wants a session"
                    )
                }
                if !canMerge {
                    return String(
                        localized: "The site refused the single-file format — install ffmpeg and this works",
                        comment: "Download failure explaining a 403 from a media site"
                    )
                }
            }
            return cleaned
        }
        return String(
            localized: "The media helper stopped with code \(Int(status))",
            comment: "Download failure from the external helper"
        )
    }
}

nonisolated private extension Int64 {
    /// An estimated total of zero is the helper saying it has no idea, not a zero-byte file.
    var nonZero: Int64? { self > 0 ? self : nil }
}
