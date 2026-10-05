//
//  DownloadItem.swift
//  tabmenu
//

import Foundation

/// What is behind a link. Decides the glyph, and the sub-folder when downloads are sorted.
nonisolated enum DownloadKind: String, Codable, Sendable, CaseIterable {
    case archive
    case video
    case audio
    case image
    case document
    case application
    case other

    var symbolName: String {
        switch self {
        case .archive: "doc.zipper"
        case .video: "film"
        case .audio: "music.note"
        case .image: "photo"
        case .document: "doc.text"
        case .application: "app.badge"
        case .other: "arrow.down.doc"
        }
    }

    /// Sub-folder name when sorting is on. Folder names are paths, not copy, so they stay
    /// in English whatever the interface language is.
    var folderName: String {
        switch self {
        case .archive: "Archives"
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .document: "Documents"
        case .application: "Apps"
        case .other: "Other"
        }
    }
}

/// How the bytes actually arrive.
nonisolated enum DownloadTransport: String, Codable, Sendable {
    /// A plain HTTP GET this app runs itself.
    case http
    /// A page whose media is fetched by the external helper the user installed.
    case mediaTool
    /// Two streams the site serves apart, fetched one after the other and then joined.
    case streamMerge
    /// An HLS or DASH manifest, which names its own segments and has to be assembled.
    case playlist
}

/// Where a two-part download has got to.
nonisolated enum MergePhase: String, Codable, Sendable {
    case video
    case audio
    /// Both parts are on disk and being joined.
    case joining
}

nonisolated enum DownloadState: String, Codable, Sendable {
    case queued
    case running
    case paused
    /// Interrupted by something that resolves itself — a dropped connection, a sleeping Mac, a
    /// server having a bad minute — and waiting to try again on its own.
    case waiting
    case completed
    case failed

    var isRunning: Bool { self == .running }
    var isFinished: Bool { self == .completed || self == .failed }
}

/// What the prompt hands back once the user has answered it.
nonisolated struct DownloadRequest: Sendable {
    let candidate: DownloadCandidate
    let fileName: String
    let folder: URL
    /// The helper preset, for a media page it will fetch itself.
    let quality: MediaQuality?
    /// The stream the page was seen playing, when a browser extension found it.
    let streamOption: StreamOption?
}

/// One transfer, as the queue and the island both see it.
///
/// Everything needed to resume lives here and is written to disk, because the offset to pick
/// up from is the size of the `.part` file rather than a token the system may have expired:
/// a download survives quitting the app, and a relaunch continues it instead of starting over.
nonisolated struct DownloadItem: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let url: URL
    /// Where the finished file goes. Editable in the prompt, so it is not derived on the fly.
    var fileName: String
    var folder: URL
    var kind: DownloadKind
    var transport: DownloadTransport
    /// `nil` when the server refuses to say how big the body is.
    var totalBytes: Int64?
    var receivedBytes: Int64
    var state: DownloadState
    var isResumable: Bool
    /// Why it failed, in the server's or the system's words.
    var failure: String?
    var addedAt: Date
    /// Quality asked of the media helper, kept so a retry uses the same one.
    var mediaQuality: String?
    /// How many times the queue has picked this up again after an interruption. Not persisted: a
    /// relaunch is a fresh start, and a download that failed yesterday deserves a clean attempt.
    var attempt: Int = 0
    /// When the next attempt is due, for the row to say so.
    var retryAt: Date?
    /// The audio track, for a site that serves picture and sound as separate streams.
    var secondaryURL: URL?
    /// Which half is in flight. Persisted, so a transfer paused halfway through the second one
    /// resumes there rather than starting the first again.
    var mergePhase: MergePhase?
    /// Bytes from the halves that already finished, so progress climbs across both instead of
    /// snapping back to zero when the second one starts.
    var completedPhaseBytes: Int64 = 0
    /// Headers to repeat on every request for this file — cookies, referer, user agent — as
    /// the browser would have sent them. Persisted, because a transfer resumed tomorrow needs
    /// the same context it started with.
    var headers: [String: String]?
    /// Live sample only. Never persisted: a speed restored from disk is a number that was
    /// true minutes ago.
    var bytesPerSecond: Double = 0

    private enum CodingKeys: String, CodingKey {
        case id, url, fileName, folder, kind, transport
        case totalBytes, receivedBytes, state, isResumable, failure, addedAt, mediaQuality
        case headers, secondaryURL, mergePhase, completedPhaseBytes
    }

    init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        folder: URL,
        kind: DownloadKind,
        transport: DownloadTransport = .http,
        totalBytes: Int64? = nil,
        receivedBytes: Int64 = 0,
        state: DownloadState = .queued,
        isResumable: Bool = false,
        failure: String? = nil,
        addedAt: Date = Date(),
        mediaQuality: String? = nil,
        headers: [String: String]? = nil,
        secondaryURL: URL? = nil,
        mergePhase: MergePhase? = nil
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.folder = folder
        self.kind = kind
        self.transport = transport
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.state = state
        self.isResumable = isResumable
        self.failure = failure
        self.addedAt = addedAt
        self.mediaQuality = mediaQuality
        self.headers = headers
        self.secondaryURL = secondaryURL
        self.mergePhase = mergePhase
    }

    var destinationURL: URL { folder.appendingPathComponent(fileName) }

    /// Partial data sits beside the destination, on the same volume, so finishing is a
    /// rename rather than a copy. The extension is one the shelf's watcher ignores, so a
    /// download in flight never announces itself as having arrived.
    var partURL: URL { folder.appendingPathComponent(fileName + ".part") }

    /// The two halves of a joined download, kept apart so each can resume on its own.
    var videoPartURL: URL { folder.appendingPathComponent(fileName + ".video.part") }
    var audioPartURL: URL { folder.appendingPathComponent(fileName + ".audio.part") }

    /// Where the half currently in flight is being written.
    var currentPartURL: URL {
        guard transport == .streamMerge else { return partURL }
        return mergePhase == .audio ? audioPartURL : videoPartURL
    }

    /// Every scratch file this download owns.
    var scratchURLs: [URL] {
        transport == .streamMerge ? [videoPartURL, audioPartURL] : [partURL]
    }

    /// `nil` when the total is unknown — a bar that guesses is worse than no bar.
    var progress: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }

    var isActive: Bool { state == .running || state == .queued || state == .waiting }

    /// Seconds left at the current rate, while there is enough to go on.
    var remainingSeconds: TimeInterval? {
        guard let totalBytes, bytesPerSecond > 1024, state == .running else { return nil }
        let remaining = Double(totalBytes - receivedBytes)
        guard remaining > 0 else { return nil }
        return remaining / bytesPerSecond
    }

    /// The one line under the file name in the queue: what it is doing, in the fewest words.
    var statusLine: String {
        switch state {
        case .queued:
            return String(localized: "Waiting", comment: "Download is queued behind others")
        case .waiting:
            let seconds = retryAt.map { max(0, $0.timeIntervalSinceNow) } ?? 0
            let reason = failure ?? String(localized: "Interrupted", comment: "Download was cut off")
            guard seconds >= 1 else {
                return String(localized: "\(reason) — trying again", comment: "Download retrying now")
            }
            return String(
                localized: "\(reason) — retrying in \(Format.countdown(seconds))",
                comment: "Download waiting to retry"
            )
        case .running where mergePhase == .joining:
            return String(localized: "Joining picture and sound", comment: "A download being muxed")
        case .running:
            let transferred = totalBytes.map { "\(Format.bytes(receivedBytes)) / \(Format.bytes($0))" }
                ?? Format.bytes(receivedBytes)
            guard bytesPerSecond > 0 else { return transferred }
            if let remainingSeconds {
                return "\(transferred) · \(Format.speed(bytesPerSecond)) · \(Format.countdown(remainingSeconds))"
            }
            return "\(transferred) · \(Format.speed(bytesPerSecond))"
        case .paused:
            let total = totalBytes.map { " / \(Format.bytes($0))" } ?? ""
            return String(
                localized: "Paused at \(Format.bytes(receivedBytes))\(total)",
                comment: "Download is paused part of the way through"
            )
        case .completed:
            return totalBytes.map(Format.bytes) ?? Format.bytes(receivedBytes)
        case .failed:
            return failure ?? String(localized: "Failed", comment: "Download did not finish")
        }
    }
}
