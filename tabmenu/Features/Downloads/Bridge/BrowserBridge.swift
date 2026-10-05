//
//  BrowserBridge.swift
//  tabmenu
//

import AppKit
import Observation
import os

/// A download the browser handed over, with the context that makes it work.
///
/// The context is the entire point. A URL on its own is often refused — signed links, session
/// cookies, referer checks — which is why copying a link out of a browser and fetching it from
/// another program so often ends in 403. What the browser was *about* to send is not a secret
/// it has to guess at: cookies, referer and user agent, replayed exactly.
/// The tab a browser is making sound with, as only the browser itself can know.
///
/// AppleScript can say which tab is in front and nothing more, so a video left running while
/// someone reads something else in another tab is invisible from outside. Chrome tracks it per
/// tab; this is that answer, arriving from the extension.
nonisolated struct BrowserPlayback: Sendable, Equatable {
    let url: URL
    let title: String
}

nonisolated struct BridgeCatch: Sendable {
    let url: URL
    let fileName: String?
    let mimeType: String?
    let byteSize: Int64?
    let referrer: String?
    let cookie: String?
    let userAgent: String?
    /// `true` when the browser had already begun this download and stood down for us, so the
    /// user is owed the file and must not be asked again.
    let wasIntercepted: Bool

    /// The headers to repeat. Cookies come first in importance: they are what a signed link,
    /// a members-only file and a paywalled asset all turn on.
    var headers: [String: String] {
        var headers: [String: String] = [:]
        if let cookie, !cookie.isEmpty { headers["Cookie"] = cookie }
        if let referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        if let userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        return headers
    }
}

/// A browser extension that has been let in.
nonisolated struct BridgeClient: Codable, Identifiable, Sendable, Equatable {
    /// The extension's origin, which the browser sets and a web page cannot forge.
    let origin: String
    var name: String
    var token: String
    var pairedAt: Date

    var id: String { origin }
}

/// Owns the loopback listener and decides what the browser is allowed to ask for.
///
/// Two rules carry the security of the whole thing. Nothing but `/ping` works without a token,
/// and a token is only ever handed out after the user has said yes to a dialog naming the
/// extension that asked. A page on the open web cannot get past either: its origin is not an
/// extension origin, and it cannot answer a dialog on the user's behalf.
@Observable
@MainActor
final class BrowserBridge {
    /// Set by the coordinator: a download to take over.
    @ObservationIgnored var onCatch: ((BridgeCatch) -> Void)?
    /// What a page turned out to be playing. Nothing is fetched from this on its own — the
    /// island offers it and the user picks a quality.
    @ObservationIgnored var onMedia: ((SniffedMedia) -> Void)?
    /// Which tab is making sound, or `nil` when none is. Description only: it never starts
    /// anything.
    @ObservationIgnored var onPlaying: ((BrowserPlayback?) -> Void)?

    private(set) var clients: [BridgeClient] = []
    private(set) var port: UInt16?
    /// Last time a browser actually used the bridge, so Settings can show it is alive.
    private(set) var lastActivity: Date?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Bridge")
    @ObservationIgnored private var server: BrowserBridgeServer?
    /// One pairing dialog at a time — a page that fires a hundred requests gets one refusal.
    @ObservationIgnored private var isPairing = false
    @ObservationIgnored private let confirm: ((String, String) async -> Bool)?

    /// Origins allowed to ask for a token at all. Only browsers can mint these schemes.
    private static let extensionSchemes = [
        "chrome-extension://", "moz-extension://", "safari-web-extension://", "extension://"
    ]

    /// - Parameter confirm: Asks the user whether an extension may connect. Injected so the
    ///   routing — including the rules that keep a web page out — can be tested without a
    ///   dialog on screen.
    init(
        preferences: Preferences,
        storageURL: URL? = nil,
        confirm: ((_ name: String, _ origin: String) async -> Bool)? = nil
    ) {
        self.preferences = preferences
        self.storageURL = storageURL
            ?? AppSupportDirectory.url().appendingPathComponent("bridge.json")
        self.confirm = confirm
        load()
    }

    // MARK: - Lifecycle

    func updateMonitoring() {
        guard preferences.isDownloadManagerEnabled, preferences.isBrowserBridgeEnabled else {
            server?.stop()
            server = nil
            port = nil
            return
        }
        guard server == nil else { return }

        let server = BrowserBridgeServer { [weak self] request in
            await self?.handle(request) ?? .error(503, "unavailable")
        }
        self.server = server
        port = server.start()
    }

    func revoke(_ client: BridgeClient) {
        clients.removeAll { $0.origin == client.origin }
        persist()
    }

    // MARK: - Routing

    /// - Note: `nonisolated` callers hop onto the main actor to get here, which is what lets a
    ///   pairing request put a dialog on screen and wait for the answer.
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let origin = Self.extensionOrigin(request.origin)

        // A preflight is answered for extension origins only; everything else is not talking
        // to us on purpose.
        if request.method == "OPTIONS" {
            guard origin != nil else { return .error(403, "forbidden") }
            return HTTPResponse(status: 200, body: Data(), allowedOrigin: origin)
        }

        switch (request.method, request.path) {
        case ("GET", "/ping"):
            return ping(origin: origin)
        case ("POST", "/pair"):
            return await pair(request, origin: origin)
        case ("POST", "/catch"):
            return handleCatch(request, origin: origin)
        case ("POST", "/media"):
            return handleMedia(request, origin: origin)
        case ("POST", "/playing"):
            return handlePlaying(request, origin: origin)
        default:
            return .error(404, "no such endpoint", origin: origin)
        }
    }

    /// Lets the extension find the app and see whether it is already paired. Deliberately
    /// answerable without a token: it says nothing a local process could not already find out
    /// by listing open ports.
    private func ping(origin: String?) -> HTTPResponse {
        let isPaired = origin.map { candidate in clients.contains { $0.origin == candidate } } ?? false
        return .json([
            "app": "MagicPlus",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "paired": isPaired
        ], origin: origin)
    }

    private func pair(_ request: HTTPRequest, origin: String?) async -> HTTPResponse {
        guard let origin else {
            return .error(403, "only a browser extension may pair", origin: nil)
        }
        // Already known: hand back the same token rather than asking the user again after a
        // browser restart.
        if let existing = clients.first(where: { $0.origin == origin }) {
            return .json(["token": existing.token], origin: origin)
        }
        guard !isPairing else {
            return .error(403, "a pairing request is already open", origin: origin)
        }

        let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let name = (payload?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (name?.isEmpty == false ? name! : origin)

        isPairing = true
        defer { isPairing = false }
        let allowed = await (confirm ?? { name, origin in
            await self.confirmPairingWithDialog(name: name, origin: origin)
        })(label, origin)
        guard allowed else {
            logger.notice("pairing refused")
            return .error(403, "refused", origin: origin)
        }

        let client = BridgeClient(
            origin: origin,
            name: label,
            token: Self.makeToken(),
            pairedAt: Date()
        )
        clients.append(client)
        persist()
        logger.notice("paired a browser extension")
        return .json(["token": client.token], origin: origin)
    }

    private func handleCatch(_ request: HTTPRequest, origin: String?) -> HTTPResponse {
        guard authorize(request, origin: origin) != nil else {
            return .error(401, "pair first", origin: origin)
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let urlString = payload["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return .error(400, "a http or https url is required", origin: origin)
        }

        lastActivity = Date()
        onCatch?(BridgeCatch(
            url: url,
            fileName: (payload["filename"] as? String).flatMap(Self.leafName),
            mimeType: payload["mime"] as? String,
            byteSize: Self.byteSize(payload["size"]),
            referrer: payload["referrer"] as? String,
            cookie: payload["cookie"] as? String,
            userAgent: payload["userAgent"] as? String,
            wasIntercepted: payload["intercepted"] as? Bool ?? false
        ))
        return .json(["accepted": true], status: 202, origin: origin)
    }

    private func handleMedia(_ request: HTTPRequest, origin: String?) -> HTTPResponse {
        guard let client = authorize(request, origin: origin) else {
            return .error(401, "pair first", origin: origin)
        }
        _ = client
        guard let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let pageString = payload["pageUrl"] as? String,
              let pageURL = URL(string: pageString),
              let rawStreams = payload["streams"] as? [[String: Any]], !rawStreams.isEmpty
        else {
            return .error(400, "a page url and at least one stream are required", origin: origin)
        }

        let streams = rawStreams.compactMap(Self.stream(from:))
        guard !streams.isEmpty else {
            return .error(400, "no usable stream", origin: origin)
        }

        lastActivity = Date()
        onMedia?(SniffedMedia(
            pageURL: pageURL,
            title: (payload["title"] as? String) ?? "",
            streams: streams,
            headers: BridgeCatch(
                url: pageURL,
                fileName: nil,
                mimeType: nil,
                byteSize: nil,
                referrer: payload["referrer"] as? String,
                cookie: payload["cookie"] as? String,
                userAgent: payload["userAgent"] as? String,
                wasIntercepted: false
            ).headers
        ))
        return .json(["accepted": true], status: 202, origin: origin)
    }

    static func stream(from payload: [String: Any]) -> SniffedStream? {
        guard let urlString = payload["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let itag = (payload["itag"] as? NSNumber)?.intValue ?? Int(payload["itag"] as? String ?? "")
        return SniffedStream(
            url: url,
            mime: (payload["mime"] as? String) ?? "",
            itag: (itag ?? 0) > 0 ? itag : nil,
            byteSize: byteSize(payload["size"]),
            label: (payload["label"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isPlaylist: payload["playlist"] as? Bool ?? false
        )
    }

    private func handlePlaying(_ request: HTTPRequest, origin: String?) -> HTTPResponse {
        guard authorize(request, origin: origin) != nil else {
            return .error(401, "pair first", origin: origin)
        }
        let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]

        lastActivity = Date()
        guard payload?["audible"] as? Bool == true,
              let address = payload?["url"] as? String,
              let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            // Nothing audible is as much of an answer as anything else.
            onPlaying?(nil)
            return .json(["accepted": true], status: 202, origin: origin)
        }

        onPlaying?(BrowserPlayback(
            url: url,
            title: ((payload?["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        ))
        return .json(["accepted": true], status: 202, origin: origin)
    }

    /// The one gate every endpoint but `/ping` passes through.
    private func authorize(_ request: HTTPRequest, origin: String?) -> BridgeClient? {
        guard let token = request.bearerToken,
              let client = clients.first(where: { Self.tokensMatch($0.token, token) }),
              origin == nil || origin == client.origin
        else { return nil }
        return client
    }

    // MARK: - Consent

    private func confirmPairingWithDialog(name: String, origin: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "Let \(name) hand downloads to MagicPlus?",
            comment: "Bridge pairing dialog title"
        )
        alert.informativeText = String(
            localized: "A browser extension is asking to pass downloads to MagicPlus, along with the cookies and referer for each one so the server accepts them. Only allow this if you installed the extension yourself.\n\n\(origin)",
            comment: "Bridge pairing dialog body"
        )
        alert.addButton(withTitle: String(localized: "Allow", comment: "Bridge pairing dialog button"))
        alert.addButton(withTitle: String(localized: "Deny", comment: "Bridge pairing dialog button"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Helpers

    /// The origin, but only if a browser extension could have sent it.
    static func extensionOrigin(_ origin: String?) -> String? {
        guard let origin else { return nil }
        let lowered = origin.lowercased()
        guard extensionSchemes.contains(where: lowered.hasPrefix) else { return nil }
        return origin
    }

    /// A browser reports the full path it would have written to; only the leaf is ours to use,
    /// and it is untrusted text either way.
    static func leafName(_ path: String) -> String? {
        let leaf = (path as NSString).lastPathComponent
        let sanitized = LinkProbe.sanitize(leaf)
        return sanitized == "download" && leaf.isEmpty ? nil : sanitized
    }

    static func byteSize(_ value: Any?) -> Int64? {
        let size: Int64?
        switch value {
        case let number as NSNumber: size = number.int64Value
        case let string as String: size = Int64(string)
        default: size = nil
        }
        guard let size, size > 0 else { return nil }
        return size
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// Compared without an early exit, so how long the answer takes says nothing about how much
    /// of the token was right.
    static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count, !left.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let stored = try? JSONDecoder().decode([BridgeClient].self, from: data)
        else { return }
        clients = stored
    }

    private func persist() {
        do {
            try JSONEncoder().encode(clients).write(to: storageURL, options: .atomic)
            // Tokens are credentials: readable by this user and nobody else.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageURL.path
            )
        } catch {
            logger.error("cannot save bridge clients: \(error.localizedDescription, privacy: .public)")
        }
    }
}
