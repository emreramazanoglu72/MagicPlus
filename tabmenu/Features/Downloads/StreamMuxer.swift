//
//  StreamMuxer.swift
//  tabmenu
//

import AVFoundation
import Foundation
import os

/// Joins a downloaded video track and audio track into one playable file, using nothing that is
/// not already on the machine.
///
/// Every large site serves picture and sound apart, so joining them is not optional — but asking
/// someone to install a command-line tool before they can download a video is a poor trade for a
/// menu bar app. macOS has carried everything needed for this for twenty years.
///
/// It copies compressed samples across rather than exporting a composition, and then it checks
/// what it produced.
///
/// The check is not ceremony. Some sites — YouTube among them — serve per-track MP4 files whose
/// timing AVFoundation reads as twice the real length: 6050 frames declared across 504 seconds on
/// a track that states 23.976 fps. `ffmpeg` silently corrects such a file; AVFoundation believes
/// it, and the picture would end up at half speed against its own sound. Rather than guess at a
/// correction, this compares the two tracks afterwards and refuses to hand over a file whose
/// halves disagree — the caller can then fall back to `ffmpeg`, which reads those files properly.
///
/// For well-formed sources, which is most of the web, this needs nothing installed at all.
///
/// The one thing AVFoundation will not write is WebM. VP9 and Opus are outside it, which is why
/// the picker asks for the MP4 family whenever this is the muxer in use — every large site offers
/// one alongside the WebM.
nonisolated enum StreamMuxer {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "Downloads")

    enum Failure: LocalizedError {
        case noVideoTrack
        case noAudioTrack
        case unsupportedFormat
        /// The two halves came out disagreeing about how long they are, which means the source's
        /// own timing could not be trusted. Recoverable: `ffmpeg` reads such files correctly.
        case outOfSync
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                String(localized: "The video part did not arrive in one piece", comment: "Muxing failure")
            case .noAudioTrack:
                String(localized: "The audio part did not arrive in one piece", comment: "Muxing failure")
            case .unsupportedFormat:
                String(
                    localized: "This format cannot be joined on this Mac — pick an MP4 quality",
                    comment: "Muxing failure for a codec macOS cannot write"
                )
            case .outOfSync:
                String(
                    localized: "Picture and sound did not line up, so nothing was saved",
                    comment: "Muxing failure when the two tracks disagree on length"
                )
            case .failed(let reason):
                reason
            }
        }
    }

    /// Containers this can write. WebM is not one of them.
    static func canMux(fileExtension: String) -> Bool {
        ["mp4", "m4v", "mov", "m4a"].contains(fileExtension.lowercased())
    }

    static func fileType(for destination: URL) -> AVFileType {
        switch destination.pathExtension.lowercased() {
        case "mov": .mov
        case "m4v": .m4v
        case "m4a": .m4a
        default: .mp4
        }
    }

    /// How far the two tracks may differ before the result is not worth handing over. Half a
    /// second is past what anyone notices between picture and sound.
    private static let syncTolerance: Double = 0.5

    /// - Parameters:
    ///   - video: A complete file holding the picture track.
    ///   - audio: A complete file holding the sound track.
    ///   - destination: Must not already exist.
    static func mux(video: URL, audio: URL, into destination: URL) async throws {
        guard canMux(fileExtension: destination.pathExtension) else { throw Failure.unsupportedFormat }

        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack
        }

        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let audioFormat = try await audioTrack.load(.formatDescriptions).first
        guard let videoFormat, let audioFormat else { throw Failure.unsupportedFormat }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType(for: destination))

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormat
        )
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: audioFormat
        )
        videoInput.expectsMediaDataInRealTime = false
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw Failure.unsupportedFormat
        }
        writer.add(videoInput)
        writer.add(audioInput)

        let videoReader = try AVAssetReader(asset: videoAsset)
        let audioReader = try AVAssetReader(asset: audioAsset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        audioOutput.alwaysCopiesSampleData = false
        videoReader.add(videoOutput)
        audioReader.add(audioOutput)

        guard writer.startWriting() else {
            throw Failure.failed(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)
        videoReader.startReading()
        audioReader.startReading()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await copy(from: videoOutput, into: videoInput, label: "video") }
            group.addTask { await copy(from: audioOutput, into: audioInput, label: "audio") }
            await group.waitForAll()
        }

        // A reader that stopped early left the file short; that is a failure, not a smaller file.
        for reader in [videoReader, audioReader] where reader.status == .failed {
            writer.cancelWriting()
            throw Failure.failed(reader.error?.localizedDescription ?? "")
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.failed(writer.error?.localizedDescription
                ?? String(localized: "Could not write the joined file", comment: "Muxing failure"))
        }

        // Checked, not trusted — and checked on the file that came out rather than on a tally of
        // what went in. A source whose picture and sound are both misdeclared by the same factor
        // agrees with itself perfectly; only the written result shows the damage.
        let (videoEnd, audioEnd) = try await trackLengths(of: destination)
        guard videoEnd > 0, audioEnd > 0, abs(videoEnd - audioEnd) <= syncTolerance else {
            try? FileManager.default.removeItem(at: destination)
            logger.notice("mux rejected: video \(videoEnd, privacy: .public)s audio \(audioEnd, privacy: .public)s")
            throw Failure.outOfSync
        }
    }

    /// Rewrites one file's tracks into a container the rest of the Mac will open.
    ///
    /// This is what an assembled HLS stream needs. Its segments concatenate into a single MPEG-TS
    /// or fragmented-MP4 file that AVFoundation reads perfectly well — verified, not assumed — but
    /// that Finder, QuickTime and every other app treat as a curiosity. Copying the compressed
    /// samples across into an MP4 costs one pass over the file and no quality at all.
    ///
    /// - Parameters:
    ///   - source: A complete file holding one or more tracks.
    ///   - destination: Must not already exist.
    static func remux(source: URL, into destination: URL) async throws {
        guard canMux(fileExtension: destination.pathExtension) else { throw Failure.unsupportedFormat }

        let asset = AVURLAsset(url: source)
        let tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        guard !tracks.isEmpty else { throw Failure.noVideoTrack }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType(for: destination))
        let reader = try AVAssetReader(asset: asset)

        var pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, label: String)] = []
        for track in tracks {
            guard let format = try await track.load(.formatDescriptions).first else { continue }
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.unsupportedFormat }
            writer.add(input)

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.unsupportedFormat }
            reader.add(output)

            pairs.append((output, input, track.mediaType.rawValue))
        }
        guard !pairs.isEmpty else { throw Failure.unsupportedFormat }

        guard writer.startWriting() else {
            throw Failure.failed(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)
        reader.startReading()

        let box = Unsafe(pairs)
        await withTaskGroup(of: Void.self) { group in
            for index in pairs.indices {
                group.addTask {
                    let pair = box.value[index]
                    await copy(from: pair.output, into: pair.input, label: pair.label)
                }
            }
            await group.waitForAll()
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw Failure.failed(reader.error?.localizedDescription ?? "")
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.failed(writer.error?.localizedDescription
                ?? String(localized: "Could not write the joined file", comment: "Muxing failure"))
        }

        // The same check as a join, for the same reason — but a file with only one track has
        // nothing to disagree with, so only a pair is compared.
        let (videoEnd, audioEnd) = try await trackLengths(of: destination)
        if videoEnd > 0, audioEnd > 0 {
            guard abs(videoEnd - audioEnd) <= syncTolerance else {
                try? FileManager.default.removeItem(at: destination)
                logger.notice("remux rejected: video \(videoEnd, privacy: .public)s audio \(audioEnd, privacy: .public)s")
                throw Failure.outOfSync
            }
        } else if videoEnd <= 0, audioEnd <= 0 {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.failed(String(localized: "The assembled stream held no playable track", comment: "Muxing failure"))
        }
    }

    /// How long each track in a finished file turned out to be.
    private static func trackLengths(of url: URL) async throws -> (video: Double, audio: Double) {
        let asset = AVURLAsset(url: url)
        var lengths: [AVMediaType: Double] = [:]
        for track in try await asset.load(.tracks) {
            lengths[track.mediaType] = try await track.load(.timeRange).duration.seconds
        }
        return (lengths[.video] ?? 0, lengths[.audio] ?? 0)
    }

    /// Pulls compressed samples from one track and hands them to the writer, at the pace the
    /// writer asks for them.
    private static func copy(
        from output: AVAssetReaderTrackOutput,
        into input: AVAssetWriterInput,
        label: String
    ) async {
        let queue = DispatchQueue(label: "com.tabmenu.mux.\(label)")
        // Neither of these is `Sendable`, and both are touched only from the serial queue the
        // writer pulls on — which is precisely the invariant `requestMediaDataWhenReady` is built
        // around. Saying so in a box is more honest than leaving the compiler to guess.
        let track = Unsafe((input: input, output: output))

        await withCheckedContinuation { continuation in
            let box = Continuation(continuation)
            input.requestMediaDataWhenReady(on: queue) {
                let (input, output) = track.value

                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        box.resume()
                        return
                    }

                    // Timestamps come across exactly as they were: the samples say when they
                    // belong, and anything this reads them through could only be wrong.
                    guard input.append(sample) else {
                        input.markAsFinished()
                        box.resume()
                        return
                    }
                }
            }
        }
    }

    /// Carries a reference the compiler cannot vouch for into a queue that can.
    private final class Unsafe<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// `requestMediaDataWhenReady` can call its block again after the samples run out, so the
    /// continuation needs to be resumed exactly once.
    private final class Continuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                let value = continuation
                continuation = nil
                return value
            }
            pending?.resume()
        }
    }
}
