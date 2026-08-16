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
    /// Anything else holding the media session; driven with hardware media keys.
    case system

    /// Player names are brands and stay as they are; only the generic fallback is translated.
    var displayName: String {
        switch self {
        case .app(let app): app.displayName
        case .system: String(localized: "System audio", comment: "Media source that could not be identified")
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .app(let app): app.bundleIdentifier
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
/// Spotify and Apple Music are queried over AppleScript for full metadata. Everything else,
/// a YouTube tab included, is still controllable through the hardware media keys — it just
/// cannot be described.
nonisolated enum MediaController {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "Media")

    /// Only players that can be asked directly are reported.
    ///
    /// Browsers are deliberately not inspected: a tab title says nothing about whether it is
    /// playing, and macOS exposes no way to ask. Claiming a paused YouTube tab is playing is
    /// worse than saying nothing — the transport controls drive it either way, through the
    /// hardware media keys.
    static func nowPlaying() -> NowPlaying? {
        // An actively playing app wins over one that is merely paused, whichever it is.
        let candidates = MediaApp.allCases
            .filter { isRunning($0.bundleIdentifier) }
            .compactMap { nowPlaying(in: $0) }
        return candidates.first { $0.isPlaying == true } ?? candidates.first
    }

    // MARK: - Playback control

    static func playPause(_ source: MediaSource) {
        switch source {
        case .app(let app): run(command: "playpause", in: app)
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
