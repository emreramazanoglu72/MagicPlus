//
//  HLSAssemblyTests.swift
//  tabmenuTests
//

import AVFoundation
import Foundation
import Testing
@testable import tabmenu

/// A directory served over HTTP, so the assembler can be pointed at a real socket rather than a
/// stub. Everything an HLS download can get wrong — the order segments land in, what happens when
/// the connection dies halfway, whether a resumed run repeats bytes it already has — only shows up
/// against something that actually answers requests.
private final class LocalServer {
    let directory: URL
    let port: Int
    private var process: Process?

    init(port: Int) throws {
        self.port = port
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hls-\(port)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    func write(_ data: Data, as name: String) throws {
        try data.write(to: directory.appendingPathComponent(name))
    }

    func write(_ text: String, as name: String) throws {
        try write(Data(text.utf8), as: name)
    }

    func start() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "http.server", "\(port)", "--directory", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process

        // Wait for it to answer rather than guessing at a sleep.
        for _ in 0..<50 {
            if (try? await answers()) == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "LocalServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "never came up"])
    }

    private func answers() async throws -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 1
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse) != nil
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    deinit {
        process?.terminate()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Collects the runner's events and hands back the one that ended it.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DownloadEvent] = []
    private var continuation: CheckedContinuation<DownloadEvent, Never>?

    var handler: @Sendable (DownloadEvent) -> Void {
        { [self] event in
            lock.withLock { events.append(event) }
            switch event {
            case .finished, .failed:
                let pending: CheckedContinuation<DownloadEvent, Never>? = lock.withLock {
                    let value = continuation
                    continuation = nil
                    return value
                }
                pending?.resume(returning: event)
            default:
                break
            }
        }
    }

    func outcome() async -> DownloadEvent {
        if let done = lock.withLock({ events.last(where: { if case .finished = $0 { true } else if case .failed = $0 { true } else { false } }) }) {
            return done
        }
        return await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    var all: [DownloadEvent] { lock.withLock { events } }
}

@Suite("HLS assembly")
struct HLSAssemblyTests {
    /// Recognisable, differently sized bodies, so a file assembled out of order or with a segment
    /// repeated is not merely the wrong length — it is visibly wrong.
    private func segmentBodies(count: Int) -> [Data] {
        (0..<count).map { index in
            Data(repeating: UInt8(65 + index), count: 1000 + index * 137)
        }
    }

    private func scratchURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    /// The core promise: every segment, once, in the order the playlist gave them.
    @Test func assemblesEverySegmentOnceInOrder() async throws {
        let server = try LocalServer(port: 27851)
        let bodies = segmentBodies(count: 7)
        for (index, body) in bodies.enumerated() {
            try server.write(body, as: "seg\(index).ts")
        }
        var playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n"
        for index in bodies.indices { playlist += "#EXTINF:4.0,\nseg\(index).ts\n" }
        playlist += "#EXT-X-ENDLIST\n"
        try server.write(playlist, as: "media.m3u8")
        try await server.start()
        defer { server.stop() }

        let scratch = scratchURL("hls-order.part")
        let destination = scratchURL("hls-order.mp4")
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: destination)

        let recorder = Recorder()
        let runner = HLSDownloadRunner(onEvent: recorder.handler)
        runner.start(
            id: UUID(),
            url: server.baseURL.appendingPathComponent("media.m3u8"),
            destination: destination,
            scratch: scratch,
            preferredHeight: nil,
            headers: [:]
        )

        let outcome = await recorder.outcome()

        // The bytes are not video, so the rewrite at the end is expected to refuse them — which is
        // itself worth knowing: a stream that holds no playable track must not be handed over as
        // if it did.
        guard case .failed(_, let reason, _) = outcome else {
            Issue.record("expected the rewrite to refuse synthetic bytes, got \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path), "nothing playable, so nothing placed")

        // What matters here: the assembled file, byte for byte.
        let assembled = try Data(contentsOf: scratch)
        #expect(assembled == bodies.reduce(Data(), +), "segments were reordered, repeated or lost")
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Segments fetched a few at a time must still be written in playlist order. Four in flight
    /// with wildly different sizes is the case that catches an assembler that writes them as they
    /// arrive.
    @Test func aWindowOfRequestsDoesNotReorderTheFile() async throws {
        let server = try LocalServer(port: 27852)
        // Descending sizes: the last request of each window finishes first if nothing enforces
        // order.
        let bodies = (0..<9).map { index in Data(repeating: UInt8(97 + index), count: 40_000 - index * 4_000) }
        for (index, body) in bodies.enumerated() { try server.write(body, as: "s\(index).ts") }
        var playlist = "#EXTM3U\n"
        for index in bodies.indices { playlist += "#EXTINF:2.0,\ns\(index).ts\n" }
        playlist += "#EXT-X-ENDLIST\n"
        try server.write(playlist, as: "i.m3u8")
        try await server.start()
        defer { server.stop() }

        let scratch = scratchURL("hls-window.part")
        try? FileManager.default.removeItem(at: scratch)

        let recorder = Recorder()
        let runner = HLSDownloadRunner(onEvent: recorder.handler)
        runner.start(
            id: UUID(),
            url: server.baseURL.appendingPathComponent("i.m3u8"),
            destination: scratchURL("hls-window.mp4"),
            scratch: scratch,
            preferredHeight: nil,
            headers: [:]
        )
        _ = await recorder.outcome()

        #expect(try Data(contentsOf: scratch) == bodies.reduce(Data(), +))
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Many segments inside one file, each taking a slice. Getting the ranges wrong produces a
    /// file of exactly the right length and entirely the wrong contents, which is the kind of bug
    /// a length check never finds.
    @Test func fetchesSegmentsThatAreSlicesOfOneFile() async throws {
        let server = try LocalServer(port: 27853)
        let whole = Data((0..<3000).map { UInt8($0 % 251) })
        try server.write(whole, as: "all.ts")
        let playlist = """
        #EXTM3U
        #EXT-X-BYTERANGE:1000@0
        #EXTINF:2.0,
        all.ts
        #EXT-X-BYTERANGE:1500
        #EXTINF:2.0,
        all.ts
        #EXT-X-BYTERANGE:500
        #EXTINF:2.0,
        all.ts
        #EXT-X-ENDLIST
        """
        try server.write(playlist, as: "r.m3u8")
        try await server.start()
        defer { server.stop() }

        let scratch = scratchURL("hls-range.part")
        try? FileManager.default.removeItem(at: scratch)

        let recorder = Recorder()
        let runner = HLSDownloadRunner(onEvent: recorder.handler)
        runner.start(
            id: UUID(),
            url: server.baseURL.appendingPathComponent("r.m3u8"),
            destination: scratchURL("hls-range.mp4"),
            scratch: scratch,
            preferredHeight: nil,
            headers: [:]
        )
        _ = await recorder.outcome()

        // The three slices are consecutive, so the assembled file is the first 3000 bytes back.
        #expect(try Data(contentsOf: scratch) == whole)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The feature the whole download queue is built around, for a shape of download that has no
    /// `Content-Length` to resume from: interrupt it, start it again, and the bytes already on disk
    /// must be kept and not repeated.
    @Test func picksUpWhereItStoppedWithoutRepeatingBytes() async throws {
        let server = try LocalServer(port: 27854)
        let bodies = segmentBodies(count: 8)
        for (index, body) in bodies.enumerated() { try server.write(body, as: "p\(index).ts") }
        var playlist = "#EXTM3U\n"
        for index in bodies.indices { playlist += "#EXTINF:3.0,\np\(index).ts\n" }
        playlist += "#EXT-X-ENDLIST\n"
        try server.write(playlist, as: "p.m3u8")
        try await server.start()

        let scratch = scratchURL("hls-resume.part")
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: scratch.appendingPathExtension("hlsresume"))

        let id = UUID()
        let url = server.baseURL.appendingPathComponent("p.m3u8")

        // First run, stopped on purpose part way through.
        let first = Recorder()
        let runner = HLSDownloadRunner(onEvent: first.handler)
        runner.start(
            id: id,
            url: url,
            destination: scratchURL("hls-resume.mp4"),
            scratch: scratch,
            preferredHeight: nil,
            headers: [:]
        )
        try await Task.sleep(for: .milliseconds(250))
        runner.pause(id: id)
        try await Task.sleep(for: .milliseconds(250))

        let partial = (try? Data(contentsOf: scratch))?.count ?? 0
        let total = bodies.reduce(0) { $0 + $1.count }
        #expect(partial > 0, "nothing was written before the pause")

        // Second run, same scratch file.
        let second = Recorder()
        let resumed = HLSDownloadRunner(onEvent: second.handler)
        resumed.start(
            id: id,
            url: url,
            destination: scratchURL("hls-resume.mp4"),
            scratch: scratch,
            preferredHeight: nil,
            headers: [:]
        )
        _ = await second.outcome()
        server.stop()

        let assembled = try Data(contentsOf: scratch)
        #expect(assembled.count == total, "resumed to \(assembled.count) of \(total) bytes")
        #expect(assembled == bodies.reduce(Data(), +), "a resumed file must be the same file")
        try? FileManager.default.removeItem(at: scratch)
    }

    @Test func refusesALiveStreamWithAReasonThatSaysWhy() async throws {
        let server = try LocalServer(port: 27855)
        try server.write(Data(repeating: 1, count: 10), as: "l0.ts")
        // No #EXT-X-ENDLIST: still being produced.
        try server.write("#EXTM3U\n#EXTINF:4.0,\nl0.ts\n", as: "live.m3u8")
        try await server.start()
        defer { server.stop() }

        let recorder = Recorder()
        let runner = HLSDownloadRunner(onEvent: recorder.handler)
        runner.start(
            id: UUID(),
            url: server.baseURL.appendingPathComponent("live.m3u8"),
            destination: scratchURL("hls-live.mp4"),
            scratch: scratchURL("hls-live.part"),
            preferredHeight: nil,
            headers: [:]
        )

        guard case .failed(_, let reason, let isTransient) = await recorder.outcome() else {
            Issue.record("a live stream should not report success")
            return
        }
        #expect(reason.contains("live") || reason.contains("canlı"))
        #expect(!isTransient, "there is no point retrying a stream that has not ended")
    }

    /// A rendition chosen by height has to be the one that gets fetched, not merely the one that
    /// was picked.
    @Test func fetchesTheRenditionThatMatchesTheChosenQuality() async throws {
        let server = try LocalServer(port: 27856)
        let small = Data(repeating: 0x11, count: 800)
        let large = Data(repeating: 0x22, count: 900)
        try server.write(small, as: "low.ts")
        try server.write(large, as: "high.ts")
        try server.write("#EXTM3U\n#EXTINF:2.0,\nlow.ts\n#EXT-X-ENDLIST\n", as: "low.m3u8")
        try server.write("#EXTM3U\n#EXTINF:2.0,\nhigh.ts\n#EXT-X-ENDLIST\n", as: "high.m3u8")
        try server.write("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x480
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        high.m3u8
        """, as: "master.m3u8")
        try await server.start()
        defer { server.stop() }

        let scratch = scratchURL("hls-quality.part")
        try? FileManager.default.removeItem(at: scratch)

        let recorder = Recorder()
        let runner = HLSDownloadRunner(onEvent: recorder.handler)
        runner.start(
            id: UUID(),
            url: server.baseURL.appendingPathComponent("master.m3u8"),
            destination: scratchURL("hls-quality.mp4"),
            scratch: scratch,
            preferredHeight: 480,
            headers: [:]
        )
        _ = await recorder.outcome()

        #expect(try Data(contentsOf: scratch) == small, "480 was asked for and 1080 was fetched")
        try? FileManager.default.removeItem(at: scratch)
    }
}

/// The one thing the offline tests cannot prove: that real segments come out as a file the rest of
/// the Mac will play. Runs against Apple's long-standing sample stream, so it needs the network and
/// is therefore asked for rather than assumed:
///
///     TEST_RUNNER_HLS_LIVE=1 xcodebuild test -only-testing:tabmenuTests/HLSLiveTests …
@Suite("HLS live", .enabled(if: ProcessInfo.processInfo.environment["HLS_LIVE"] == "1"))
struct HLSLiveTests {
    /// A playlist of our own naming a handful of Apple's real segments: real media over the real
    /// network, without pulling seventeen megabytes to learn one thing.
    @Test func realSegmentsBecomeAPlayableFile() async throws {
        let cdn = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear1"
        var playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<6 {
            playlist += "#EXTINF:9.97667,\n\(cdn)/fileSequence\(index).ts\n"
        }
        playlist += "#EXT-X-ENDLIST\n"

        let server = try LocalServer(port: 27861)
        try server.write(playlist, as: "live.m3u8")
        try await server.start()
        defer { server.stop() }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hls-real.part")
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hls-real.mp4")
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: destination)

        let manifestURL = server.baseURL.appendingPathComponent("live.m3u8")

        let recorder = Recorder()
        let runner = HLSDownloadRunner(onEvent: recorder.handler)
        runner.start(
            id: UUID(),
            url: manifestURL,
            destination: destination,
            scratch: scratch,
            preferredHeight: nil,
            headers: [:]
        )

        let outcome = await recorder.outcome()
        guard case .finished(_, let bytes) = outcome else {
            Issue.record("assembly failed: \(outcome), events: \(recorder.all)")
            return
        }
        #expect(bytes > 500_000)

        // The claim being tested: the result is a file with picture and sound in it, of the length
        // the playlist promised — not merely a file of the right size.
        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.load(.tracks)
        let video = tracks.filter { $0.mediaType == .video }
        let audio = tracks.filter { $0.mediaType == .audio }
        #expect(video.count == 1, "no video track in the finished file")
        #expect(audio.count == 1, "no audio track in the finished file")

        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 59.86) < 2.0, "six ten-second segments came out as \(duration)s")

        // And the scratch files are gone: a finished download leaves nothing behind.
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathExtension("hlsresume").path))

        print("LIVE HLS: \(Int(duration))s, \(bytes / 1024)KB, \(tracks.count) tracks")
        try? FileManager.default.removeItem(at: destination)
    }
}
