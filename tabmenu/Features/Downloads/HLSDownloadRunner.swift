//
//  HLSDownloadRunner.swift
//  MagicPlus
//

import Foundation
import os

/// Fetches an HLS stream by fetching everything it is made of.
///
/// A manifest is a list of a few hundred small files, so this is not a download in the sense the
/// rest of the queue means: there is no single response to resume and no `Content-Length` to
/// believe. What it does instead:
///
/// - reads the manifest, picks the rendition closest to the quality asked for, and — when the site
///   serves sound apart from picture — takes both;
/// - fetches segments a few at a time but appends them strictly in order, because a stream is only
///   playable in the order it was written;
/// - records how far it got beside the file it is writing, so quitting the app costs the segment in
///   flight rather than the hour already spent;
/// - hands the assembled file to `StreamMuxer`, which turns MPEG-TS or fragmented MP4 into an MP4
///   the rest of the Mac will open.
///
/// Nothing here needs anything installed. That was the point: HLS was the last shape of video that
/// asked the user for `ffmpeg` first.
nonisolated final class HLSDownloadRunner: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.tabmenu", category: "Downloads")
    private let onEvent: @Sendable (DownloadEvent) -> Void
    private let session: URLSession

    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Cancelled on purpose by the user, so the queue is told "paused" rather than "failed".
    private var pausing: Set<UUID> = []

    /// How many segments are in flight at once. One at a time spends most of its life waiting for
    /// the next round trip; a hundred at once is a denial of service with our name on it.
    private static let window = 4
    /// A segment is a small file on a big CDN. Losing one to a hiccup should cost a retry, not the
    /// whole stream.
    private static let attemptsPerSegment = 3

    init(onEvent: @escaping @Sendable (DownloadEvent) -> Void) {
        self.onEvent = onEvent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = Self.window
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - scratch: Where the assembled stream is built. Siblings of it hold the sound track and
    ///     the resume note, and all of them are removed once the file is handed over.
    ///   - preferredHeight: From the quality the user picked, or `nil` for the best on offer.
    func start(
        id: UUID,
        url: URL,
        destination: URL,
        scratch: URL,
        preferredHeight: Int?,
        headers: [String: String]
    ) {
        cancelTask(id: id)
        let task = Task.detached { [weak self] () -> Void in
            await self?.run(
                id: id,
                url: url,
                destination: destination,
                scratch: scratch,
                preferredHeight: preferredHeight,
                headers: headers
            )
        }
        lock.withLock { tasks[id] = task }
    }

    func pause(id: UUID) {
        lock.withLock { _ = pausing.insert(id) }
        cancelTask(id: id)
    }

    func cancel(id: UUID) {
        cancelTask(id: id)
        lock.withLock { _ = pausing.remove(id) }
    }

    private func cancelTask(id: UUID) {
        let task = lock.withLock { tasks.removeValue(forKey: id) }
        task?.cancel()
    }

    // MARK: - The run

    private func run(
        id: UUID,
        url: URL,
        destination: URL,
        scratch: URL,
        preferredHeight: Int?,
        headers: [String: String]
    ) async {
        do {
            let manifest = try await fetchText(url, headers: headers)

            let videoPlaylistURL: URL
            var audioPlaylistURL: URL?

            switch HLS.kind(of: manifest) {
            case .notAPlaylist:
                throw Failure.notAPlaylist
            case .media:
                videoPlaylistURL = url
            case .master:
                let master = HLS.parseMaster(manifest, baseURL: url)
                guard let variant = master.variant(preferredHeight: preferredHeight) else {
                    throw Failure.noRendition
                }
                videoPlaylistURL = variant.url
                audioPlaylistURL = master.audio(for: variant)?.url
                logger.notice("hls variant \(variant.height ?? 0, privacy: .public)p, separate audio: \(audioPlaylistURL != nil, privacy: .public)")
            }

            let videoFile = scratch
            let audioFile = scratch.appendingPathExtension("audio")

            let video = try await media(at: videoPlaylistURL, headers: headers)
            var audio: HLS.Media?
            if let audioPlaylistURL {
                audio = try await media(at: audioPlaylistURL, headers: headers)
            }

            // Progress across both halves, so the bar climbs once instead of twice.
            let totalSegments = video.segments.count + (audio?.segments.count ?? 0)
            let counter = Counter(id: id, totalSegments: totalSegments, onEvent: onEvent)

            onEvent(.started(id: id, totalBytes: nil, receivedBytes: 0, isResumable: true))

            try await assemble(video, into: videoFile, headers: headers, counter: counter)
            if let audio {
                try await assemble(audio, into: audioFile, headers: headers, counter: counter)
            }

            try Task.checkCancellation()

            // AVFoundation decides what a file holds from its extension and refuses to open one it
            // does not recognise — and the assembled stream is sitting in a `.part` file. So it is
            // presented under a name that says what it is. A hard link rather than a copy: the same
            // bytes, not a second gigabyte on disk.
            let videoTyped = try typedLink(for: videoFile, fragmented: video.initSegment != nil)
            defer { try? FileManager.default.removeItem(at: videoTyped) }

            if let audio {
                let audioTyped = try typedLink(for: audioFile, fragmented: audio.initSegment != nil)
                defer { try? FileManager.default.removeItem(at: audioTyped) }
                try await StreamMuxer.mux(video: videoTyped, audio: audioTyped, into: destination)
            } else {
                try await StreamMuxer.remux(source: videoTyped, into: destination)
            }

            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
            cleanUp(scratch: scratch)
            lock.withLock { tasks[id] = nil }
            onEvent(.finished(id: id, receivedBytes: size ?? counter.bytes))
        } catch is CancellationError {
            let wasPausing = lock.withLock { pausing.remove(id) != nil }
            lock.withLock { tasks[id] = nil }
            // A pause keeps the scratch files; that is the whole point of them.
            if !wasPausing {
                onEvent(.failed(id: id, reason: String(localized: "Cancelled", comment: "Download failure"), isTransient: false))
            }
        } catch {
            lock.withLock { tasks[id] = nil }
            let failure = error as? Failure
            onEvent(.failed(
                id: id,
                reason: failure?.message ?? error.localizedDescription,
                isTransient: failure?.isTransient ?? true
            ))
        }
    }

    /// Reads a media playlist and refuses, with a reason, the ones that cannot be fetched.
    private func media(at url: URL, headers: [String: String]) async throws -> HLS.Media {
        let text = try await fetchText(url, headers: headers)
        guard HLS.kind(of: text) == .media else { throw Failure.notAPlaylist }

        let media = HLS.parseMedia(text, baseURL: url)
        switch media.obstacle {
        case .live: throw Failure.live
        case .encrypted(let method): throw Failure.encrypted(method)
        case .empty: throw Failure.emptyPlaylist
        case nil: return media
        }
    }

    // MARK: - Assembly

    private func assemble(
        _ media: HLS.Media,
        into fileURL: URL,
        headers: [String: String],
        counter: Counter
    ) async throws {
        let note = ResumeNote.url(for: fileURL)
        var startIndex = 0

        // Pick up where a previous run stopped, but only if the note still describes this file.
        if let saved = ResumeNote.read(at: note),
           saved.segments <= media.segments.count,
           saved.bytes == fileSize(at: fileURL),
           saved.segmentCount == media.segments.count {
            startIndex = saved.segments
            counter.add(bytes: saved.bytes, segments: saved.segments)
            logger.notice("hls resuming at segment \(startIndex, privacy: .public)/\(media.segments.count, privacy: .public)")
        } else {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: note)
        }

        // Only when it is not already there: creating over a file being resumed would throw away
        // exactly the bytes this method exists to keep.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        // The initialisation segment is part of the file, not of the count, and only the first
        // run writes it.
        if startIndex == 0, let initSegment = media.initSegment {
            let data = try await fetch(initSegment, headers: headers)
            try handle.write(contentsOf: data)
            counter.add(bytes: Int64(data.count), segments: 0)
        }

        var index = startIndex
        var writtenBytes = fileSize(at: fileURL)

        while index < media.segments.count {
            try Task.checkCancellation()

            let upper = min(index + Self.window, media.segments.count)
            let batch = Array(media.segments[index..<upper])

            let fetched = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (offset, segment) in batch.enumerated() {
                    group.addTask { [self] in (offset, try await fetch(segment, headers: headers)) }
                }
                var result: [Int: Data] = [:]
                for try await (offset, data) in group { result[offset] = data }
                return result
            }

            // Written in the order the playlist gave them, whatever order they arrived in.
            for offset in batch.indices {
                guard let data = fetched[offset] else { throw Failure.segmentMissing }
                try handle.write(contentsOf: data)
                writtenBytes += Int64(data.count)
            }

            index = upper
            counter.add(bytes: 0, segments: batch.count)
            counter.report(totalBytesOnDisk: writtenBytes)
            try handle.synchronize()
            ResumeNote.write(
                ResumeNote(segments: index, bytes: writtenBytes, segmentCount: media.segments.count),
                at: note
            )
        }

        try? FileManager.default.removeItem(at: note)
    }

    private func fetch(_ segment: HLS.Segment, headers: [String: String]) async throws -> Data {
        var lastError: Error?

        for attempt in 1...Self.attemptsPerSegment {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: segment.url)
                for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
                if let range = segment.byteRange {
                    request.setValue(range.headerValue, forHTTPHeaderField: "Range")
                }

                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 || status == 206 else {
                    throw Failure.segmentRefused(status)
                }
                guard !data.isEmpty else { throw Failure.segmentMissing }

                // A server that ignores `Range` answers 200 with the whole file. Appending that
                // where a slice was asked for produces a stream of exactly plausible length and
                // entirely wrong contents, so the slice is taken here instead — which works
                // whichever way the server chose to answer.
                if let range = segment.byteRange, status == 200 {
                    let start = Int(range.offset)
                    let end = start + Int(range.length)
                    guard data.count >= end else { throw Failure.segmentTruncated }
                    return data.subdata(in: start..<end)
                }

                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < Self.attemptsPerSegment {
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                }
            }
        }

        throw lastError ?? Failure.segmentMissing
    }

    private func fetchText(_ url: URL, headers: [String: String]) async throws -> String {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.manifestRefused(status) }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notAPlaylist }
        return text
    }

    /// The assembled stream under a name AVFoundation will open.
    ///
    /// - Parameter fragmented: Whether the playlist carried an initialisation segment, which is
    ///   what distinguishes fragmented MP4 from MPEG-TS. Both are readable; neither is readable
    ///   through a `.part` extension.
    private func typedLink(for file: URL, fragmented: Bool) throws -> URL {
        let link = file.appendingPathExtension(fragmented ? "mp4" : "ts")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.linkItem(at: file, to: link)
        return link
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func cleanUp(scratch: URL) {
        let manager = FileManager.default
        for url in [scratch, scratch.appendingPathExtension("audio")] {
            try? manager.removeItem(at: url)
            try? manager.removeItem(at: ResumeNote.url(for: url))
            for suffix in ["ts", "mp4"] {
                try? manager.removeItem(at: url.appendingPathExtension(suffix))
            }
        }
    }

    // MARK: - Progress

    /// Progress for something with no `Content-Length`.
    ///
    /// A segmented stream cannot say how big it is until it is finished, so the total is estimated
    /// from what the segments so far have averaged and revised as it goes. An estimate that
    /// improves is more use than an empty bar.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private let id: UUID
        private let totalSegments: Int
        private let onEvent: @Sendable (DownloadEvent) -> Void
        private let startedAt = Date()
        private var doneSegments = 0
        private(set) var bytes: Int64 = 0
        private var lastReport = Date.distantPast

        init(id: UUID, totalSegments: Int, onEvent: @escaping @Sendable (DownloadEvent) -> Void) {
            self.id = id
            self.totalSegments = totalSegments
            self.onEvent = onEvent
        }

        func add(bytes: Int64, segments: Int) {
            lock.withLock {
                self.bytes += bytes
                doneSegments += segments
            }
        }

        func report(totalBytesOnDisk: Int64) {
            let payload: (bytes: Int64, estimate: Int64?, speed: Double)? = lock.withLock {
                bytes = totalBytesOnDisk
                let elapsed = Date().timeIntervalSince(startedAt)
                let speed = elapsed > 0 ? Double(bytes) / elapsed : 0
                // Throttled: a progress event per segment on a 900-segment stream is noise.
                guard Date().timeIntervalSince(lastReport) > 0.4 else { return nil }
                lastReport = Date()

                var estimate: Int64?
                if doneSegments > 0, totalSegments > 0 {
                    estimate = Int64(Double(bytes) / Double(doneSegments) * Double(totalSegments))
                }
                return (bytes, estimate, speed)
            }

            guard let payload else { return }
            if let estimate = payload.estimate {
                onEvent(.resized(id: id, totalBytes: estimate))
            }
            onEvent(.progress(id: id, receivedBytes: payload.bytes, bytesPerSecond: payload.speed))
        }
    }

    /// How far assembly got, written beside the file it describes.
    ///
    /// Kept here rather than in the queue's own store because it is about bytes on disk, not about
    /// what the user asked for: it is only valid for this exact file and this exact playlist, and
    /// a note that does not match both is thrown away rather than trusted.
    private struct ResumeNote: Codable {
        let segments: Int
        let bytes: Int64
        /// How long the playlist was when the note was written. A playlist that has since changed
        /// length is a different playlist, and its segment numbers mean something else.
        let segmentCount: Int

        static func url(for fileURL: URL) -> URL {
            fileURL.appendingPathExtension("hlsresume")
        }

        static func read(at url: URL) -> ResumeNote? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ResumeNote.self, from: data)
        }

        static func write(_ note: ResumeNote, at url: URL) {
            guard let data = try? JSONEncoder().encode(note) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Failures

    private enum Failure: Error {
        case notAPlaylist
        case noRendition
        case live
        case encrypted(String)
        case emptyPlaylist
        case manifestRefused(Int)
        case segmentRefused(Int)
        case segmentMissing
        /// A slice was asked for and the answer was too short to contain it.
        case segmentTruncated

        var message: String {
            switch self {
            case .notAPlaylist:
                String(localized: "That address is not a stream this can read", comment: "HLS failure")
            case .noRendition:
                String(localized: "The stream listed no quality to download", comment: "HLS failure")
            case .live:
                String(localized: "This is a live stream, so it has no end to download to", comment: "HLS failure")
            case .encrypted(let method):
                String(
                    localized: "The stream is encrypted (\(method)), which this cannot open",
                    comment: "HLS failure naming the encryption method"
                )
            case .emptyPlaylist:
                String(localized: "The stream listed no segments", comment: "HLS failure")
            case .manifestRefused(let status):
                String(localized: "The site refused the stream list (\(status))", comment: "HLS failure with HTTP status")
            case .segmentRefused(let status):
                String(localized: "The site refused part of the stream (\(status))", comment: "HLS failure with HTTP status")
            case .segmentMissing:
                String(localized: "Part of the stream did not arrive", comment: "HLS failure")
            case .segmentTruncated:
                String(localized: "The site sent less of the stream than it promised", comment: "HLS failure")
            }
        }

        /// Whether waiting and trying again is worth doing.
        var isTransient: Bool {
            switch self {
            case .segmentRefused(let status), .manifestRefused(let status):
                // 408, 429 and the 5xx family are the site having a moment; a 404 is not.
                return status == 408 || status == 429 || (500...599).contains(status)
            case .segmentMissing, .segmentTruncated:
                return true
            case .notAPlaylist, .noRendition, .live, .encrypted, .emptyPlaylist:
                return false
            }
        }
    }
}
