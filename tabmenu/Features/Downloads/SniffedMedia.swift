//
//  SniffedMedia.swift
//  tabmenu
//

import Foundation

/// One media stream a page was seen fetching.
nonisolated struct SniffedStream: Sendable, Hashable {
    let url: URL
    /// As the site described it — `video/mp4`, `audio/webm`, or empty for a plain file.
    let mime: String
    /// YouTube's format number, when this came from its media edge.
    let itag: Int?
    let byteSize: Int64?
    /// The site's own name for the quality, where there was one.
    let label: String?
    /// An HLS or DASH manifest rather than a stream: it names its own tracks and carries both.
    let isPlaylist: Bool

    /// Formats that carry sound as well as picture. Everything else YouTube serves is one track
    /// on its own, which is why a download from it has to be joined back together.
    private static let progressiveItags: Set<Int> = [17, 18, 22, 36, 43, 59, 78]
    private static let audioItags: Set<Int> = [139, 140, 141, 171, 172, 249, 250, 251, 256, 258]

    var isAudioOnly: Bool {
        if let itag { return Self.audioItags.contains(itag) }
        return mime.hasPrefix("audio/")
    }

    /// Whether this one file is the whole thing.
    var isComplete: Bool {
        if isPlaylist { return true }
        if let itag { return Self.progressiveItags.contains(itag) }
        // A plain `.mp4` on a web server has its audio in it; only a site that hands out
        // separate tracks says so through an itag.
        return !mime.hasPrefix("audio/")
    }

    var isVideoOnly: Bool { !isComplete && !isAudioOnly }

    /// Height in pixels, read from the label the site used. Only for ordering.
    var height: Int? {
        guard let label, let value = label.split(separator: "p").first else { return nil }
        return Int(value)
    }

    var fileExtension: String {
        if isPlaylist { return "mp4" }
        let mime = mime.lowercased()
        // Order matters here: `application/x-mpegurl` contains "mpeg", and reading it as an MP3
        // is how a picker ends up offering the same wrong thing four times.
        if mime.contains("mpegurl") || mime.contains("dash") { return "mp4" }
        if mime.contains("webm") { return isAudioOnly ? "weba" : "webm" }
        if mime.contains("mp4") || mime.contains("m4a") { return isAudioOnly ? "m4a" : "mp4" }
        if mime.contains("mpeg") || mime.contains("mp3") { return "mp3" }
        if mime.contains("ogg") { return "ogg" }
        if mime.contains("matroska") { return "mkv" }
        if mime.contains("quicktime") { return "mov" }

        let pathExtension = url.pathExtension.lowercased()
        if !pathExtension.isEmpty, pathExtension.count <= 5 { return pathExtension }
        return isAudioOnly ? "m4a" : "mp4"
    }

    /// The shortest true thing that can be said about the format itself — for when the site gave
    /// no quality to quote.
    var formatName: String {
        if isPlaylist { return "HLS" }
        let subtype = mime.lowercased().split(separator: "/").last.map(String.init) ?? ""
        switch subtype {
        case let value where value.contains("mpegurl"): return "HLS"
        case let value where value.contains("dash"): return "DASH"
        case "": return fileExtension.uppercased()
        default:
            // `x-matroska` and friends carry a prefix nobody needs to read.
            let cleaned = subtype.replacingOccurrences(of: "x-", with: "")
            return cleaned.uppercased()
        }
    }
}

/// A choice offered for a page: one download, whatever it takes to produce it.
nonisolated struct StreamOption: Identifiable, Sendable, Hashable {
    let id: String
    /// What the picker shows — "1080p · 14,5 MB".
    let label: String
    let url: URL
    /// The audio track to fetch alongside, for a site that serves the two apart.
    let audioURL: URL?
    let byteSize: Int64?
    let fileExtension: String
    /// A manifest rather than a stream: it names segments that have to be assembled.
    var isPlaylist = false

    /// Two tracks have to be fetched and joined rather than simply downloaded.
    var needsMerge: Bool { audioURL != nil }
}

/// What a page is playing, as the extension saw it.
nonisolated struct SniffedMedia: Sendable {
    let pageURL: URL
    let title: String
    let streams: [SniffedStream]
    let headers: [String: String]

    /// The choices worth putting in front of someone.
    ///
    /// A site that serves picture and sound apart — which is every large one now — turns each
    /// video track into "this quality, with the best available audio", because nobody wants a
    /// silent film. Those need `ffmpeg`, so where it is missing they are left out rather than
    /// offered and then failed.
    /// - Parameter hasFfmpeg: Whether the external tool is available. macOS joins the MP4 family
    ///   on its own, so it is only needed for WebM pairs and for assembling playlists.
    func options(hasFfmpeg: Bool) -> [StreamOption] {
        let bestAudio = streams
            .filter(\.isAudioOnly)
            .max { ($0.byteSize ?? 0) < ($1.byteSize ?? 0) }

        var options: [StreamOption] = []

        // Ready-made files first: nothing to join, nothing to install, and resumable.
        for stream in streams.filter(\.isComplete).sorted(by: Self.betterFirst) {
            // A manifest is not a file. Assembling one needs the external tool for now, so
            // offering it without that would be offering a download of a text playlist.
            if stream.isPlaylist, !hasFfmpeg { continue }
            options.append(StreamOption(
                id: stream.url.absoluteString,
                label: Self.label(for: stream),
                url: stream.url,
                audioURL: nil,
                byteSize: stream.byteSize,
                fileExtension: stream.fileExtension,
                isPlaylist: stream.isPlaylist
            ))
        }

        if let bestAudio {
            for stream in streams.filter(\.isVideoOnly).sorted(by: Self.betterFirst) {
                let container = Self.container(video: stream, audio: bestAudio)
                // macOS writes the MP4 family and nothing else, so a WebM pair is only offered
                // where the external tool can take it.
                guard StreamMuxer.canMux(fileExtension: container) || hasFfmpeg else { continue }

                let total = (stream.byteSize ?? 0) + (bestAudio.byteSize ?? 0)
                options.append(StreamOption(
                    id: stream.url.absoluteString,
                    label: Self.label(for: stream),
                    url: stream.url,
                    audioURL: bestAudio.url,
                    byteSize: total > 0 ? total : nil,
                    fileExtension: container
                ))
            }
        }

        if let bestAudio {
            options.append(StreamOption(
                id: bestAudio.url.absoluteString,
                label: Self.label(
                    for: bestAudio,
                    extra: String(localized: "Audio only", comment: "Video download quality")
                ),
                url: bestAudio.url,
                audioURL: nil,
                byteSize: bestAudio.byteSize,
                fileExtension: bestAudio.fileExtension
            ))
        }
        return Self.disambiguated(options)
    }

    /// A picker whose rows all read the same is not a picker.
    ///
    /// Sites that say nothing useful about their streams — no quality, no length — can produce
    /// several that describe identically. Rather than leave someone choosing between four
    /// indistinguishable rows, the repeats are numbered.
    static func disambiguated(_ options: [StreamOption]) -> [StreamOption] {
        var counts: [String: Int] = [:]
        for option in options { counts[option.label, default: 0] += 1 }

        var seen: [String: Int] = [:]
        return options.map { option in
            guard counts[option.label, default: 0] > 1 else { return option }
            let index = seen[option.label, default: 0] + 1
            seen[option.label] = index
            return StreamOption(
                id: option.id,
                label: "\(option.label) (\(index))",
                url: option.url,
                audioURL: option.audioURL,
                byteSize: option.byteSize,
                fileExtension: option.fileExtension
            )
        }
    }

    /// Best picture first, so the top of the list is what most people want.
    private static func betterFirst(_ lhs: SniffedStream, _ rhs: SniffedStream) -> Bool {
        if let left = lhs.height, let right = rhs.height, left != right { return left > right }
        return (lhs.byteSize ?? 0) > (rhs.byteSize ?? 0)
    }

    /// What a row says.
    ///
    /// The site's own quality label first, because "1080p" is what someone is choosing between.
    /// Failing that, whatever is actually known: what kind of track it is, the format, and the
    /// size. A row has to be distinguishable from the one under it or the picker is decoration.
    /// - Parameter carriesAudio: Whether the row will produce something with sound in it. A
    ///   video track paired with an audio track does, so it is not labelled as picture-only.
    static func label(for stream: SniffedStream, extra: String? = nil, carriesAudio: Bool = true) -> String {
        var parts: [String] = []
        if let extra {
            parts.append(extra)
        } else if stream.isAudioOnly {
            parts.append(String(localized: "Audio", comment: "A sniffed audio-only stream"))
        } else if !carriesAudio {
            parts.append(String(localized: "Video only", comment: "A sniffed stream with no sound"))
        }

        if let quality = stream.label, !quality.isEmpty {
            parts.append(quality)
        } else if stream.isPlaylist {
            parts.append(String(localized: "Live stream", comment: "A sniffed HLS or DASH playlist"))
        } else {
            parts.append(stream.formatName)
        }

        if let size = stream.byteSize { parts.append(Format.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    /// A container both tracks can be copied into without re-encoding. Mixing families needs
    /// one that takes anything.
    private static func container(video: SniffedStream, audio: SniffedStream) -> String {
        let videoFamily = video.mime.contains("webm") ? "webm" : "mp4"
        let audioFamily = audio.mime.contains("webm") ? "webm" : "mp4"
        guard videoFamily == audioFamily else { return "mkv" }
        return videoFamily == "webm" ? "webm" : "mp4"
    }
}
