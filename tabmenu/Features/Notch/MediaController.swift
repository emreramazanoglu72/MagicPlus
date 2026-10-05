//
//  MediaController.swift
//  tabmenu
//

import AppKit
import os

nonisolated enum MediaApp: String, Sendable, CaseIterable {
    case spotify
    case music

    var bundleIdentifier: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }

    /// Name as AppleScript addresses the application.
    var scriptName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Music"
        }
    }

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Apple Music"
        }
    }
}

nonisolated enum MediaSource: Sendable, Equatable {
    /// A player tabmenu can query and drive directly.
    case app(MediaApp)
    /// A page in a browser that is producing sound. Named, because "System audio" is not what
    /// anyone would call the video they are watching.
    case browser(WebBrowser)
    /// Anything else holding the media session; driven with hardware media keys.
    case system

    /// Player names are brands and stay as they are; only the generic fallback is translated.
    var displayName: String {
        switch self {
        case .app(let app): app.displayName
        case .browser(let browser): browser.scriptName
        case .system: String(localized: "System audio", comment: "Media source that could not be identified")
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .app(let app): app.bundleIdentifier
        case .browser(let browser): browser.bundleIdentifier
        case .system: nil
        }
    }
}

nonisolated struct NowPlaying: Equatable, Sendable {
    let source: MediaSource
    let title: String
    let artist: String
    let album: String
    /// Unknown for sources that cannot be queried, only driven.
    let isPlaying: Bool?
    let artworkURL: URL?
    /// Playback position and track length in seconds, when the source reports them.
    let position: Double?
    let duration: Double?
    /// The page this came from, for a browser source. Its own still frame stands in for cover
    /// art, which a page has and a player would have handed over directly.
    var pageURL: URL?

    var progress: Double? {
        guard let position, let duration, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Resolves what is playing and drives playback.
///
/// Spotify and Apple Music are queried over AppleScript for full metadata. A browser is asked
/// too, but only once Core Audio has confirmed sound is actually coming out of it — that
/// measurement is what makes the answer honest, and it is also the only condition under which a
/// page's title is read at all. Everything else is still controllable through the hardware media
/// keys; it just cannot be described.
nonisolated enum MediaController {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "Media")

    /// What is playing, in order of how well it can be described.
    ///
    /// A dedicated player that answers questions comes first. Failing that, a browser with sound
    /// coming out of it — which used to be reported as nothing at all, and "nothing playing" over
    /// a running video is the one answer that is plainly wrong.
    ///
    /// The old reasoning was that a tab title says nothing about whether it is playing. That was
    /// true of the title alone; it is not true of the title paired with Core Audio's own account
    /// of which processes are producing output.
    /// - Parameter reportedTab: The tab a browser extension says is making the sound. Exact
    ///   where it is available, and the only way to be right about a video playing in a tab
    ///   nobody is looking at.
    static func nowPlaying(reportedTab: BrowserPlayback? = nil) -> NowPlaying? {
        // An actively playing app wins over one that is merely paused, whichever it is.
        let candidates = MediaApp.allCases
            .filter { isRunning($0.bundleIdentifier) }
            .compactMap { nowPlaying(in: $0) }
        if let playing = candidates.first(where: { $0.isPlaying == true }) { return playing }
        if let browser = nowPlayingInBrowser(reportedTab: reportedTab) { return browser }
        return candidates.first
    }

    /// The page a browser is making sound with.
    ///
    /// Two sources of truth, and they are used together rather than one instead of the other.
    /// Core Audio says *whether* a browser is producing output, which is a fact. The extension
    /// says *which tab* is doing it, which nothing outside the browser can know — AppleScript can
    /// only report the tab in front, so a video left running while someone reads something else
    /// would otherwise be described as whatever they moved on to.
    ///
    /// Audibility gating the extension's report also means a stale one cannot linger: the moment
    /// the sound stops, so does this.
    private static func nowPlayingInBrowser(reportedTab: BrowserPlayback?) -> NowPlaying? {
        let audible = BrowserTabReader.audibleBrowsers(in: AudioProcessRegistry.snapshot())
        guard !audible.isEmpty else { return nil }

        if let reportedTab, let browser = audible.first {
            return playing(url: reportedTab.url, title: reportedTab.title, browser: browser)
        }

        // No extension: the tab in front is the best guess available.
        for browser in audible {
            guard case .tab(let tab) = BrowserTabReader.currentTab(in: browser) else { continue }
            return playing(url: tab.url, title: tab.title, browser: browser)
        }
        return nil
    }

    private static func playing(url: URL, title: String, browser: WebBrowser) -> NowPlaying {
        let shown = title.isEmpty ? (url.host() ?? browser.scriptName) : title
        return NowPlaying(
            source: .browser(browser),
            title: Self.trimmedTitle(shown, browser: browser),
            artist: Self.site(of: url),
            album: "",
            // Sound is coming out of it: this one is measured, not assumed.
            isPlaying: true,
            artworkURL: nil,
            position: nil,
            duration: nil,
            pageURL: url
        )
    }

    /// Browsers append their own name to every title. It is the least useful part of a line with
    /// room for one.
    static func trimmedTitle(_ title: String, browser: WebBrowser) -> String {
        var trimmed = title
        for suffix in [" - \(browser.scriptName)", " — \(browser.scriptName)", " - YouTube"]
        where trimmed.hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count))
        }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    /// The site, as someone would say it.
    static func site(of url: URL) -> String {
        guard let host = url.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Playback control

    static func playPause(_ source: MediaSource) {
        switch source {
        case .app(let app): run(command: "playpause", in: app)
        // A browser takes the hardware keys like anything else: there is no scripting interface
        // to a page's player, and the keys reach it perfectly well.
        default: sendMediaKey { MediaKeySender.playPause() }
        }
    }

    static func nextTrack(_ source: MediaSource) {
        switch source {
        case .app(let app): run(command: "next track", in: app)
        default: sendMediaKey { MediaKeySender.nextTrack() }
        }
    }

    static func previousTrack(_ source: MediaSource) {
        switch source {
        case .app(let app): run(command: "previous track", in: app)
        default: sendMediaKey { MediaKeySender.previousTrack() }
        }
    }

    private static func sendMediaKey(_ send: @escaping @MainActor () -> Void) {
        Task { @MainActor in send() }
    }

    // MARK: - Players

    private static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private static func nowPlaying(in app: MediaApp) -> NowPlaying? {
        let artworkLine = app == .spotify
            ? "set artworkValue to artwork url of current track"
            : "set artworkValue to \"\""
        // Spotify reports track length in milliseconds, Music in seconds.
        let durationLine = app == .spotify
            ? "set trackDuration to (duration of current track) / 1000"
            : "set trackDuration to duration of current track"

        let script = """
        tell application "\(app.scriptName)"
            if it is not running then return ""
            if player state is stopped then return ""
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            \(artworkLine)
            \(durationLine)
            set trackPosition to player position
            set playing to (player state as text)
            return trackName & "\\n" & trackArtist & "\\n" & trackAlbum & "\\n" & artworkValue ¬
                & "\\n" & playing & "\\n" & trackPosition & "\\n" & trackDuration
        end tell
        """

        guard let output = runScript(script), !output.isEmpty else { return nil }
        let fields = output.components(separatedBy: "\n")
        guard fields.count >= 5, !fields[0].isEmpty else { return nil }

        return NowPlaying(
            source: .app(app),
            title: fields[0],
            artist: fields[1],
            album: fields[2],
            isPlaying: fields[4].trimmingCharacters(in: .whitespaces) == "playing",
            artworkURL: fields[3].isEmpty ? nil : URL(string: fields[3]),
            position: fields.count > 5 ? parseSeconds(fields[5]) : nil,
            duration: fields.count > 6 ? parseSeconds(fields[6]) : nil
        )
    }

    /// AppleScript coerces reals to text with the system locale's decimal separator, so
    /// "73,244" arrives on Turkish/German/French systems where Double() expects "73.244".
    private static func parseSeconds(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: "."))
    }

    private static func run(command: String, in app: MediaApp) {
        _ = runScript("""
        tell application "\(app.scriptName)"
            if it is running then \(command)
        end tell
        """)
    }

    // MARK: - Script runner

    /// `osascript` is spawned rather than using `NSAppleScript` so the call never blocks the
    /// main thread; macOS asks for Automation permission the first time it runs.
    @discardableResult
    private static func runScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("AppleScript failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
