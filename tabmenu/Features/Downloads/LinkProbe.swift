//
//  LinkProbe.swift
//  tabmenu
//

import Foundation

/// A link that could be downloaded, with everything the prompt needs to describe it.
nonisolated struct DownloadCandidate: Identifiable, Sendable, Hashable {
    /// Replaced when a picked stream turns out to be the thing to fetch rather than the page.
    var url: URL
    var fileName: String
    var kind: DownloadKind
    var byteSize: Int64?
    var isResumable: Bool
    var transport: DownloadTransport
    /// Page title, when the source was a media page rather than a file.
    var title: String?
    /// Ready-made choices, when a browser extension saw what a page was playing. Empty for
    /// everything else, which is what the prompt keys its picker off.
    var streamOptions: [StreamOption] = []
    /// Headers to repeat, as the browser would have sent them.
    var headers: [String: String] = [:]

    var id: URL { url }

    /// Where it came from, as someone would say it out loud. "www." is three syllables of
    /// nothing in a space with room for very little.
    var host: String {
        guard let host = url.host() else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What the capsule and the prompt call it: the page's title where there is one, the
    /// file name otherwise.
    var displayName: String { title ?? fileName }
}

/// What a link turned out to be.
///
/// "Unreachable" and "a web page" are different answers and have to stay different: a link that
/// refuses to be asked about usually downloads perfectly, while a page downloads its own markup
/// and calls it a file. Collapsing the two into `nil` is exactly how a YouTube address ends up
/// saved as HTML.
nonisolated enum ProbeOutcome: Sendable, Equatable {
    case file(DownloadCandidate)
    /// Markup, with nothing to suggest it is meant to be saved.
    case page
    /// The server would not say. Not a reason to refuse: plenty of links behind a login answer
    /// nothing to a probe and serve the file on a real request.
    case unreachable
}

/// Works out what a link is before a byte is committed to it.
///
/// A `HEAD` is enough for well-behaved servers and costs nothing. Plenty are not well
/// behaved — S3 pre-signed links and PHP endpoints answer 403 or 405 to `HEAD` while serving
/// the same URL happily over `GET` — so the fallback asks for the first byte and hangs up.
nonisolated enum LinkProbe {
    /// A probe is a courtesy, not the download: it must never hold the prompt open for long.
    private static let timeout: TimeInterval = 8

    /// Extensions that are a file however the server describes them. A link ending in `.zip`
    /// is offered even when the probe fails outright, which is what makes the feature work on
    /// servers behind a login wall.
    private static let fileExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "iso", "img",
        "mp4", "mkv", "mov", "avi", "webm", "m4v", "flv", "wmv",
        "mp3", "m4a", "flac", "wav", "aac", "ogg", "opus",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp", "tiff",
        "pdf", "epub", "csv", "json", "xml", "txt", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "app", "ipa", "apk", "deb", "rpm", "exe", "msi", "jar", "whl", "torrent"
    ]

    // MARK: - Classification

    static func isProbablyFile(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    static func kind(forExtension extension: String, mimeType: String?) -> DownloadKind {
        switch `extension`.lowercased() {
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso", "img":
            return .archive
        case "dmg", "pkg", "app", "ipa", "apk", "deb", "rpm", "exe", "msi":
            return .application
        case "mp4", "mkv", "mov", "avi", "webm", "m4v", "flv", "wmv":
            return .video
        case "mp3", "m4a", "flac", "wav", "aac", "ogg", "opus":
            return .audio
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp", "tiff":
            return .image
        case "pdf", "epub", "csv", "json", "xml", "txt", "doc", "docx", "xls", "xlsx", "ppt", "pptx":
            return .document
        default:
            break
        }

        guard let mimeType = mimeType?.lowercased() else { return .other }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("text/") || mimeType.contains("pdf") { return .document }
        if mimeType.contains("zip") || mimeType.contains("compressed") || mimeType.contains("tar") {
            return .archive
        }
        return .other
    }

    // MARK: - Names

    /// The name the file should be saved under.
    ///
    /// `Content-Disposition` wins when the server sends one — it is the only party that knows
    /// what the bytes are called, and download endpoints routinely have a path that does not
    /// say. Otherwise the last path component, percent-decoded and stripped of its query.
    static func fileName(from response: HTTPURLResponse?, url: URL) -> String {
        if let disposition = response?.value(forHTTPHeaderField: "Content-Disposition"),
           let name = fileName(fromDisposition: disposition) {
            return sanitize(name)
        }

        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let trimmed = last.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty, trimmed != "." else {
            let host = url.host()?.replacingOccurrences(of: ".", with: "-") ?? "download"
            return sanitize(host)
        }
        return sanitize(trimmed)
    }

    /// Handles both forms in the wild: `filename*=UTF-8''name.zip`, which carries the
    /// encoding, and the plain quoted `filename="name.zip"`.
    static func fileName(fromDisposition value: String) -> String? {
        for part in value.components(separatedBy: ";") {
            let field = part.trimmingCharacters(in: .whitespaces)
            let lower = field.lowercased()

            if lower.hasPrefix("filename*=") {
                let raw = String(field.dropFirst("filename*=".count))
                guard let encoded = raw.components(separatedBy: "''").last ?? raw.components(separatedBy: "'").last
                else { continue }
                let unquoted = encoded.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let decoded = unquoted.removingPercentEncoding, !decoded.isEmpty { return decoded }
            }

            if lower.hasPrefix("filename=") {
                let raw = String(field.dropFirst("filename=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !raw.isEmpty { return raw }
            }
        }
        return nil
    }

    /// Names arrive from servers, so they are untrusted input: a `Content-Disposition` of
    /// `../../.zshrc` must not be able to write outside the download folder.
    static func sanitize(_ name: String) -> String {
        let stripped = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .filter { !$0.isEmpty && $0 != ".." && $0 != "." }
            .joined(separator: "-")
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "download" }
        // HFS+ and APFS both cap a component at 255 bytes; leave room for ".part".
        return String(trimmed.prefix(200))
    }

    // MARK: - Probing

    /// Asks the server what the link is.
    static func inspect(_ url: URL, headers: [String: String] = [:]) async -> ProbeOutcome {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .unreachable
        }

        var response = await head(url, headers: headers)
        if response == nil { response = await firstByte(url, headers: headers) }

        guard let response else {
            // Nothing came back, so the address itself is all there is to go on.
            if HLS.looksLikePlaylist(url: url, contentType: nil) {
                return .file(streamCandidate(for: url))
            }
            guard isProbablyFile(url) else { return .unreachable }
            return .file(DownloadCandidate(
                url: url,
                fileName: fileName(from: nil, url: url),
                kind: kind(forExtension: url.pathExtension, mimeType: nil),
                byteSize: nil,
                isResumable: false,
                transport: .http,
                title: nil
            ))
        }

        let mimeType = response.value(forHTTPHeaderField: "Content-Type")?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces)
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition")

        // A manifest is not a file to save: it is a list of the files the stream is made of, and
        // saving it verbatim gives the user a few kilobytes of text where they expected a video.
        if HLS.looksLikePlaylist(url: url, contentType: mimeType) {
            return .file(streamCandidate(for: url))
        }

        guard isDownloadable(url: url, mimeType: mimeType, disposition: disposition) else {
            return .page
        }

        let name = fileName(from: response, url: url)
        return .file(DownloadCandidate(
            url: url,
            fileName: name,
            kind: kind(forExtension: (name as NSString).pathExtension, mimeType: mimeType),
            byteSize: contentLength(from: response),
            isResumable: response.value(forHTTPHeaderField: "Accept-Ranges")?
                .lowercased().contains("bytes") ?? false,
            transport: .http,
            title: nil
        ))
    }

    /// A stream, named after the page it came from rather than after `index.m3u8` — which is what
    /// almost every manifest in the world is called.
    static func streamCandidate(for url: URL) -> DownloadCandidate {
        let stem = url.deletingLastPathComponent().lastPathComponent
        let base = stem.isEmpty || stem == "/" ? (url.host() ?? "stream") : stem
        return DownloadCandidate(
            url: url,
            fileName: "\(base).mp4",
            kind: .video,
            byteSize: nil,
            // A manifest never says how big the stream is; the assembler estimates as it goes.
            isResumable: true,
            transport: .playlist,
            title: nil
        )
    }

    /// Whether what the server described is a file rather than a page.
    ///
    /// Markup only counts when the server says to save it, or the address plainly names a file —
    /// otherwise a download of a web page is a download of its source, which is nobody's
    /// intention when they paste a link.
    static func isDownloadable(url: URL, mimeType: String?, disposition: String?) -> Bool {
        let isAttachment = disposition?.lowercased().contains("attachment") ?? false
        if isAttachment { return true }
        if isProbablyFile(url) { return true }
        guard let mimeType = mimeType?.lowercased() else { return true }
        return !(mimeType.hasPrefix("text/html") || mimeType.hasPrefix("application/xhtml"))
    }

    /// Convenience for the callers that only care about a file.
    static func probe(_ url: URL, headers: [String: String] = [:]) async -> DownloadCandidate? {
        guard case .file(let candidate) = await inspect(url, headers: headers) else { return nil }
        return candidate
    }

    private static func contentLength(from response: HTTPURLResponse) -> Int64? {
        // A ranged probe reports the length of the one byte it asked for, so the total has
        // to come out of Content-Range instead.
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.components(separatedBy: "/").last,
           let value = Int64(total.trimmingCharacters(in: .whitespaces)) {
            return value
        }
        guard response.expectedContentLength > 0 else { return nil }
        return response.expectedContentLength
    }

    private static func head(_ url: URL, headers: [String: String]) async -> HTTPURLResponse? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return await HeaderProbe.response(for: request)
    }

    /// Second attempt for servers that dislike `HEAD`: ask for one byte, which also reveals
    /// whether ranges are honoured at all.
    private static func firstByte(_ url: URL, headers: [String: String]) async -> HTTPURLResponse? {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = timeout
        return await HeaderProbe.response(for: request)
    }
}

/// Reads a response's headers and hangs up before the body.
///
/// The convenience methods on `URLSession` have no way to stop after the headers, and the
/// fallback probe is exactly the case where that matters: a server that dislikes `HEAD` may
/// also ignore the range, and answering "how big is this" would then mean pulling a whole
/// film into memory. Cancelling in `didReceive response` costs one round trip and no bytes.
private final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse?, Never>?
    private var session: URLSession?

    static func response(for request: URLRequest) async -> HTTPURLResponse? {
        await withCheckedContinuation { continuation in
            HeaderProbe().start(request, continuation: continuation)
        }
    }

    private func start(_ request: URLRequest, continuation: CheckedContinuation<HTTPURLResponse?, Never>) {
        lock.withLock { self.continuation = continuation }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        lock.withLock { self.session = session }
        session.dataTask(with: request).resume()
    }

    /// Resumes exactly once, whichever callback gets there first, and lets the session go —
    /// it holds this object as its delegate until it is invalidated.
    private func finish(_ response: HTTPURLResponse?) {
        let (continuation, session): (CheckedContinuation<HTTPURLResponse?, Never>?, URLSession?) = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            let session = self.session
            self.session = nil
            return (pending, session)
        }
        session?.invalidateAndCancel()
        continuation?.resume(returning: response)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.cancel)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            finish(nil)
            return
        }
        finish(http)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(nil)
    }
}
