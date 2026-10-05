//
//  HLSPlaylist.swift
//  MagicPlus
//

import Foundation

/// Reading an HLS manifest.
///
/// Why this exists: HLS was the one shape of video the app could not fetch on its own. A stream
/// served as `.m3u8` is not a file — it is a list of a few hundred small files — so there was
/// nothing for the ordinary downloader to resume, and the queue handed the whole job to `ffmpeg`.
/// That put an install step in front of exactly the sites people most often want something from,
/// and it contradicted the promise the rest of the app keeps: nothing to install.
///
/// So the app reads the manifest itself. Parsing is kept here, apart from the network and the
/// filesystem, because a manifest is a text format with a great many small rules and each of them
/// is worth a test.
nonisolated enum HLS {
    /// What a manifest turned out to be. A master playlist lists renditions; a media playlist
    /// lists segments; anything else is not ours to read.
    enum Kind: Sendable, Equatable {
        case master
        case media
        case notAPlaylist
    }

    struct ByteRange: Sendable, Equatable {
        let offset: Int64
        let length: Int64

        var headerValue: String { "bytes=\(offset)-\(offset + length - 1)" }
    }

    struct Segment: Sendable, Equatable {
        let url: URL
        /// Set when many segments share one file and each takes a slice of it.
        let byteRange: ByteRange?
        let duration: Double
    }

    struct Variant: Sendable, Equatable {
        let url: URL
        let bandwidth: Int
        /// From `RESOLUTION`, when the manifest bothers to say.
        let height: Int?
        /// The `AUDIO` group this rendition expects its sound to come from, if sound is separate.
        let audioGroup: String?
    }

    struct Rendition: Sendable, Equatable {
        let type: String
        let groupID: String
        let name: String?
        let language: String?
        let url: URL?
        let isDefault: Bool
    }

    struct Master: Sendable {
        let variants: [Variant]
        let renditions: [Rendition]

        /// The rendition to fetch for a wanted height.
        ///
        /// Not simply the closest: a stream asked for at 1080 should never come back at 2160 and
        /// four times the size, so this takes the tallest rendition that does not exceed what was
        /// asked for, and only reaches upward when everything on offer is smaller. Manifests that
        /// declare no resolution at all fall back to bandwidth, which is all they have said.
        func variant(preferredHeight: Int?) -> Variant? {
            guard !variants.isEmpty else { return nil }
            guard let preferredHeight else {
                return variants.max { $0.bandwidth < $1.bandwidth }
            }

            let withHeight = variants.filter { $0.height != nil }
            guard !withHeight.isEmpty else {
                return variants.max { $0.bandwidth < $1.bandwidth }
            }

            let fitting = withHeight.filter { ($0.height ?? 0) <= preferredHeight }
            if let best = fitting.max(by: { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }) {
                return best
            }
            // Everything is bigger than asked for, so take the smallest of them.
            return withHeight.min { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }
        }

        /// The sound track a rendition expects, when the manifest serves sound apart from picture.
        func audio(for variant: Variant) -> Rendition? {
            guard let group = variant.audioGroup else { return nil }
            let candidates = renditions.filter { $0.type == "AUDIO" && $0.groupID == group && $0.url != nil }
            return candidates.first { $0.isDefault } ?? candidates.first
        }
    }

    /// Why a manifest cannot be fetched. Each of these is a real thing manifests do, and each
    /// deserves its own sentence rather than a shrug.
    enum Obstacle: Sendable, Equatable {
        /// No `#EXT-X-ENDLIST`: the stream is still being produced and has no last segment.
        case live
        /// `#EXT-X-KEY` naming a method we do not implement.
        case encrypted(String)
        case empty
    }

    struct Media: Sendable {
        let initSegment: Segment?
        let segments: [Segment]
        let duration: Double
        let obstacle: Obstacle?

        var isUsable: Bool { obstacle == nil && !segments.isEmpty }
    }

    // MARK: - Recognition

    static func kind(of text: String) -> Kind {
        guard text.hasPrefix("#EXTM3U") || text.contains("\n#EXTM3U") else { return .notAPlaylist }
        if text.contains("#EXT-X-STREAM-INF") { return .master }
        if text.contains("#EXTINF") { return .media }
        // A master with only audio renditions, or a manifest we cannot use; treat as master so
        // the caller looks for renditions rather than segments.
        return text.contains("#EXT-X-MEDIA") ? .master : .notAPlaylist
    }

    /// Whether a URL or content type is worth reading as a playlist at all.
    static func looksLikePlaylist(url: URL, contentType: String?) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" || url.pathExtension.lowercased() == "m3u" {
            return true
        }
        guard let contentType = contentType?.lowercased() else { return false }
        return contentType.contains("mpegurl") || contentType.contains("x-mpegurl")
    }

    // MARK: - Parsing

    static func parseMaster(_ text: String, baseURL: URL) -> Master {
        var variants: [Variant] = []
        var renditions: [Rendition] = []
        var pendingVariant: [String: String]?

        for line in lines(of: text) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = attributes(in: String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                continue
            }

            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = attributes(in: String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard let type = attributes["TYPE"], let group = attributes["GROUP-ID"] else { continue }
                renditions.append(
                    Rendition(
                        type: type,
                        groupID: group,
                        name: attributes["NAME"],
                        language: attributes["LANGUAGE"],
                        url: attributes["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL },
                        isDefault: attributes["DEFAULT"]?.uppercased() == "YES"
                    )
                )
                continue
            }

            guard !line.hasPrefix("#"), let attributes = pendingVariant else { continue }
            pendingVariant = nil

            guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
            variants.append(
                Variant(
                    url: url,
                    bandwidth: attributes["BANDWIDTH"].flatMap { Int($0) }
                        ?? attributes["AVERAGE-BANDWIDTH"].flatMap { Int($0) } ?? 0,
                    height: attributes["RESOLUTION"].flatMap { resolution in
                        resolution.split(separator: "x").last.flatMap { Int($0) }
                    },
                    audioGroup: attributes["AUDIO"]
                )
            )
        }

        return Master(variants: variants, renditions: renditions)
    }

    static func parseMedia(_ text: String, baseURL: URL) -> Media {
        var segments: [Segment] = []
        var initSegment: Segment?
        var duration: Double = 0
        var pendingDuration: Double = 0
        var pendingRange: ByteRange?
        var hasEndList = false
        var encryption: String?
        /// Where the previous slice of a shared file ended, for a `BYTERANGE` that omits its
        /// offset — the spec says it continues from the last one.
        var rangeCursor: Int64 = 0

        for line in lines(of: text) {
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                pendingDuration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), cursor: rangeCursor)
                continue
            }

            if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = attributes(in: String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attributes["URI"], let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                    let range = attributes["BYTERANGE"].flatMap { byteRange($0, cursor: 0) }
                    initSegment = Segment(url: url, byteRange: range, duration: 0)
                }
                continue
            }

            if line.hasPrefix("#EXT-X-KEY:") {
                let method = attributes(in: String(line.dropFirst("#EXT-X-KEY:".count)))["METHOD"] ?? "UNKNOWN"
                // A key line that turns encryption off again is not an obstacle.
                encryption = method.uppercased() == "NONE" ? nil : method
                continue
            }

            if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
                continue
            }

            guard !line.hasPrefix("#") else { continue }
            guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }

            segments.append(Segment(url: url, byteRange: pendingRange, duration: pendingDuration))
            duration += pendingDuration
            if let pendingRange { rangeCursor = pendingRange.offset + pendingRange.length }
            pendingDuration = 0
            pendingRange = nil
        }

        let obstacle: Obstacle? = {
            if let encryption { return .encrypted(encryption) }
            if segments.isEmpty { return .empty }
            // A playlist still being written has no end to download to.
            if !hasEndList { return .live }
            return nil
        }()

        return Media(initSegment: initSegment, segments: segments, duration: duration, obstacle: obstacle)
    }

    // MARK: - Line and attribute reading

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func byteRange(_ value: String, cursor: Int64) -> ByteRange? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard let length = parts.first.flatMap({ Int64($0) }) else { return nil }
        let offset = parts.count > 1 ? (Int64(parts[1]) ?? cursor) : cursor
        return ByteRange(offset: offset, length: length)
    }

    /// Splits an attribute list, respecting quotes.
    ///
    /// `CODECS="avc1.4d401f,mp4a.40.2"` holds a comma inside its value, so splitting the line on
    /// commas loses half the attributes after it — which is how a manifest ends up looking like it
    /// has no resolution.
    static func attributes(in list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingValue = false
        var inQuotes = false

        func commit() {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            guard !trimmedKey.isEmpty else { return }
            result[trimmedKey] = value.trimmingCharacters(in: .whitespaces)
            key = ""
            value = ""
            readingValue = false
        }

        for character in list {
            switch character {
            case "\"":
                inQuotes.toggle()
            case "=" where !readingValue && !inQuotes:
                readingValue = true
            case "," where !inQuotes:
                commit()
            default:
                if readingValue { value.append(character) } else { key.append(character) }
            }
        }
        commit()
        return result
    }
}
