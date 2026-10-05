//
//  StreamMergeRunner.swift
//  tabmenu
//

import Foundation
import os

/// Fetches one or two streams and writes a single playable file, by handing both to `ffmpeg`.
///
/// This is the piece that makes a sniffed download useful. Every large site now serves picture
/// and sound as separate tracks, so a video track downloaded on its own is a silent film; IDM
/// carries its own muxer for exactly this and joins the two as they arrive. `ffmpeg` already
/// does it, copies both streams without re-encoding, and speaks HLS and DASH playlists as well
/// — one runner covers all three cases.
///
/// The cost is honest and worth stating: a mux cannot be resumed. Pausing one of these stops it,
/// and starting it again starts it again.
nonisolated final class StreamMergeRunner: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.tabmenu", category: "Downloads")
    private let onEvent: @Sendable (DownloadEvent) -> Void
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var pausing: Set<UUID> = []

    init(onEvent: @escaping @Sendable (DownloadEvent) -> Void) {
        self.onEvent = onEvent
    }

    // MARK: - Arguments

    /// - Parameter headers: Repeated on every input. `ffmpeg` takes them as one blob before the
    ///   `-i` they belong to, and a signed media URL is refused without the cookie that goes
    ///   with it just as surely as any other download.
    static func arguments(
        video: URL,
        audio: URL?,
        destination: URL,
        headers: [String: String]
    ) -> [String] {
        var arguments = ["-y", "-loglevel", "error", "-progress", "pipe:1", "-nostdin"]

        let blob = headers
            .filter { $0.key.lowercased() != "user-agent" }
            .map { "\($0.key): \($0.value)\r\n" }
            .joined()

        func input(_ url: URL) -> [String] {
            var arguments: [String] = []
            // Headers and reconnection are options of the HTTP protocol; offered for a local file
            // they are not merely useless, `ffmpeg` refuses the whole command over them.
            if !url.isFileURL {
                if let agent = headers["User-Agent"] { arguments += ["-user_agent", agent] }
                if !blob.isEmpty { arguments += ["-headers", blob] }
                // A long transfer over a flaky line should not throw the whole join away.
                arguments += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
            }
            arguments += ["-i", url.isFileURL ? url.path : url.absoluteString]
            return arguments
        }

        arguments += input(video)
        if let audio { arguments += input(audio) }

        // Copy, never re-encode: this is a download, not a conversion.
        arguments += ["-c", "copy"]
        if audio != nil { arguments += ["-map", "0:v:0", "-map", "1:a:0"] }
        if destination.pathExtension.lowercased() == "mp4" {
            arguments += ["-movflags", "+faststart"]
        }
        arguments.append(destination.path)
        return arguments
    }

    /// Joins two files that are already on disk.
    ///
    /// The fallback for the one thing macOS will not do: some sites — YouTube among them — write
    /// per-track files whose timing AVFoundation reads as twice the real length, and `ffmpeg`
    /// reads them correctly. Nothing is downloaded here; both halves are already local.
    static func mux(video: URL, audio: URL, into destination: URL, tool: URL) async throws {
        try? FileManager.default.removeItem(at: destination)

        let arguments = Self.arguments(
            video: video,
            audio: audio,
            destination: destination,
            headers: [:]
        )

        let message: String? = try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.environment = MediaTool.environment()

            let pipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = pipe

            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus != 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .split(separator: "\n").last.map(String.init)
        }.value

        if let message {
            throw MuxFailure.failed(Self.reason(from: message))
        }
    }

    enum MuxFailure: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let reason): reason }
        }
    }

    // MARK: - Control

    func start(
        id: UUID,
        video: URL,
        audio: URL?,
        destination: URL,
        expected: Int64?,
        headers: [String: String],
        tool: URL
    ) {
        let process = Process()
        process.executableURL = tool
        process.environment = MediaTool.environment()
        process.arguments = Self.arguments(
            video: video,
            audio: audio,
            destination: destination,
            headers: headers
        )

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        lock.withLock {
            processes[id] = process
            pausing.remove(id)
        }

        Task.detached(priority: .utility) { [weak self] in
            await self?.pump(id: id, process: process, pipe: pipe, expected: expected)
        }
    }

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

    private func pump(id: UUID, process: Process, pipe: Pipe, expected: Int64?) async {
        do {
            try process.run()
        } catch {
            finish(id: id, event: .failed(id: id, reason: error.localizedDescription, isTransient: false))
            return
        }
        try? pipe.fileHandleForWriting.close()

        onEvent(.started(id: id, totalBytes: expected, receivedBytes: 0, isResumable: false))

        var written: Int64 = 0
        var lastMessage: String?

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                // `-progress` prints `key=value` a block at a time; the size is the only field
                // that answers "how far along is this".
                if line.hasPrefix("total_size=") {
                    guard let value = Int64(line.dropFirst("total_size=".count)) else { continue }
                    written = value
                    onEvent(.progress(id: id, receivedBytes: value, bytesPerSecond: 0))
                } else if !line.contains("="), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    lastMessage = line.trimmingCharacters(in: .whitespaces)
                }
            }
        } catch {
            logger.error("merge output ended: \(error.localizedDescription, privacy: .public)")
        }

        process.waitUntilExit()

        if lock.withLock({ pausing.contains(id) }) {
            finish(id: id, event: nil)
            return
        }
        guard process.terminationStatus == 0 else {
            finish(id: id, event: .failed(id: id, reason: Self.reason(from: lastMessage), isTransient: false))
            return
        }
        finish(id: id, event: .finished(id: id, receivedBytes: written))
    }

    private func finish(id: UUID, event: DownloadEvent?) {
        lock.withLock {
            processes[id] = nil
            pausing.remove(id)
        }
        if let event { onEvent(event) }
    }

    /// `ffmpeg`'s last line is usually the useful one — a 403 on the stream, or a container that
    /// will not take a codec.
    static func reason(from message: String?) -> String {
        guard let message, !message.isEmpty else {
            return String(localized: "The streams could not be joined", comment: "Download failure")
        }
        if message.contains("403") || message.lowercased().contains("forbidden") {
            return String(
                localized: "The site refused the stream — it may have expired, so play the page again",
                comment: "Download failure for an expired media URL"
            )
        }
        return message
    }
}
