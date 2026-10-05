//
//  MediaTool.swift
//  tabmenu
//

import AppKit
import Foundation
import os

/// Qualities offered for a media page.
///
/// Presets rather than the raw format table the helper prints: a list of sixty numbered
/// formats is a developer's view of a video, and every one of them still has to be paired with
/// an audio track by hand.
nonisolated enum MediaQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case best
    case p1080
    case p720
    case p480
    case audio

    var id: String { rawValue }

    /// The tallest rendition this quality accepts, for a manifest that names its resolutions.
    /// `nil` means "whatever is best".
    var maximumHeight: Int? {
        switch self {
        case .best: nil
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        // Sound only: the smallest picture on offer is the cheapest thing to throw away.
        case .audio: 1
        }
    }


    var title: String {
        switch self {
        case .best: String(localized: "Best available", comment: "Video download quality")
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .audio: String(localized: "Audio only", comment: "Video download quality")
        }
    }

    /// Format selector in the helper's own syntax.
    ///
    /// Separate video and audio come first wherever they can be joined, and that order is not
    /// a preference. YouTube has been retiring the single-file "progressive" formats: asking
    /// for one now answers `403 Forbidden` on most videos, while the same video downloads
    /// perfectly as two streams. Without `ffmpeg` there is nothing to join them with, so the
    /// single file is all that is left — which is precisely why `ffmpeg` is worth installing.
    ///
    /// - Parameter canMerge: whether `ffmpeg` is on the machine.
    func selector(canMerge: Bool) -> String {
        switch self {
        case .best: canMerge ? "bv*+ba/b" : "b"
        case .p1080: Self.selector(upTo: 1080, canMerge: canMerge)
        case .p720: Self.selector(upTo: 720, canMerge: canMerge)
        case .p480: Self.selector(upTo: 480, canMerge: canMerge)
        // Audio arrives as its own stream, so this one never needs joining.
        case .audio: "ba[ext=m4a]/ba/b"
        }
    }

    private static func selector(upTo height: Int, canMerge: Bool) -> String {
        canMerge
            ? "bv*[height<=?\(height)]+ba/b[height<=?\(height)]/b"
            : "b[height<=?\(height)]/b"
    }

    /// Whether this preset depends on `ffmpeg` being present to be reliable at all.
    var needsMerger: Bool { self != .audio }
}

/// Browser whose cookies the helper is allowed to read.
///
/// YouTube increasingly refuses the stream URLs it just handed out unless the request carries a
/// session — the download starts, a few megabytes arrive, and then every range comes back 403.
/// Signed-in cookies are the documented way through it, and they are also what gets an
/// age-restricted or members-only page to play at all.
///
/// It is off by default and has to stay that way: this hands the user's session to another
/// program, which is a decision only they can make.
nonisolated enum MediaCookieSource: String, CaseIterable, Identifiable, Sendable {
    case none
    case safari
    case chrome
    case brave
    case edge
    case firefox
    case vivaldi
    case opera

    var id: String { rawValue }

    /// Name the helper knows the browser by. `nil` for the off state.
    var helperName: String? { self == .none ? nil : rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "Don't use cookies", comment: "Media cookie source: off")
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .firefox: "Firefox"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        }
    }
}

nonisolated struct MediaPageInfo: Sendable {
    let title: String
    let durationSeconds: Double?
}

/// Talks to the external media helper — `yt-dlp` — that the user installs themselves.
///
/// Nothing here is bundled and nothing is downloaded on the user's behalf: MagicPlus ships no
/// site extractors, keeps no plugin list, and does nothing at all unless a helper binary is
/// already on the machine. What it does is hand a page URL to that binary and draw a progress
/// bar for it, which is the part a menu bar app can honestly own.
nonisolated enum MediaTool {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "Downloads")

    /// Where the helper lands with Homebrew, MacPorts, pipx and a plain `pip --user`.
    static let searchPaths = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/opt/local/bin/yt-dlp",
        "/usr/bin/yt-dlp"
    ]

    static let installCommand = "brew install yt-dlp ffmpeg"
    /// Where Homebrew itself lives, on Apple silicon and on Intel.
    private static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// Directories put on the helper's `PATH`, so it can find `ffmpeg` when a preset needs
    /// two streams joined. A spawned process inherits none of the shell's own additions.
    private static let toolSearchPath = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"

    /// The helper to use: whatever the user pointed at, otherwise the first well-known path
    /// that exists. `nil` means the feature stays out of the way entirely.
    static func resolve(configuredPath: String) -> URL? {
        let manager = FileManager.default
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            return manager.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/yt-dlp").path
        for path in searchPaths + [home] where manager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Pages the helper is worth asking about.
    ///
    /// Deliberately a short list of sites people actually watch things on, not an attempt to
    /// mirror what the helper supports: offering to download every page in the browser would
    /// be noise, and guessing wrong costs a network round trip each time.
    private static let mediaHosts: Set<String> = [
        "youtube.com", "youtu.be", "vimeo.com", "dailymotion.com", "twitch.tv",
        "soundcloud.com", "bandcamp.com", "tiktok.com", "twitter.com", "x.com"
    ]

    static func isMediaPage(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard mediaHosts.contains(bare) || mediaHosts.contains(where: { bare.hasSuffix(".\($0)") })
        else { return false }

        // A site's front page is not a video. Something has to identify one.
        if bare.hasSuffix("youtube.com") {
            return url.path() == "/watch" || url.path().hasPrefix("/shorts/") || url.path().hasPrefix("/live/")
        }
        return url.path().count > 1
    }

    // MARK: - Metadata

    /// Title and length of a page, for the prompt. Extraction is a network round trip, so the
    /// caller shows the URL first and fills this in when it arrives.
    static func pageInfo(for url: URL, tool: URL, cookies: MediaCookieSource = .none) async -> MediaPageInfo? {
        var arguments = [
            "--no-playlist", "--skip-download", "--no-warnings", "--quiet",
            "--print", "%(title)s", "--print", "%(duration)s"
        ]
        // The same session that gets the download through is what makes a restricted page
        // report a title at all.
        if let browser = cookies.helperName {
            arguments += ["--cookies-from-browser", browser]
        }
        arguments.append(url.absoluteString)

        let output = await run(tool: tool, arguments: arguments)
        let lines = (output ?? "").split(separator: "\n", omittingEmptySubsequences: true)
        guard let title = lines.first.map(String.init), !title.isEmpty else { return nil }

        let duration = lines.count > 1 ? Double(lines[1].trimmingCharacters(in: .whitespaces)) : nil
        return MediaPageInfo(title: title, durationSeconds: duration)
    }

    // MARK: - Installing

    static func homebrew() -> URL? {
        brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    /// Runs the install in a Terminal window the user can watch.
    ///
    /// Deliberately not run inside the app: `brew` takes minutes, prints a great deal, and
    /// occasionally asks something. A visible shell is honest about all three, and the user
    /// can stop it. A script opened with `NSWorkspace` also needs no Automation permission,
    /// which scripting Terminal directly would.
    ///
    /// - Returns: `false` when Homebrew is not installed either, so the caller can send the
    ///   user to its own instructions instead.
    @discardableResult
    static func runInstaller() -> Bool {
        guard let brew = homebrew() else {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            return false
        }

        let script = [
            "#!/bin/sh",
            "echo 'MagicPlus: installing the media helper'",
            "echo '\(installCommand)'",
            "echo",
            "'\(brew.path)' install yt-dlp ffmpeg",
            "status=$?",
            "echo",
            "if [ $status -eq 0 ]; then",
            "  echo 'Done. MagicPlus picks it up on the next link you give it.'",
            "else",
            "  echo \"Homebrew exited with $status. Nothing in MagicPlus was changed.\"",
            "fi",
            ""
        ].joined(separator: "\n")

        let url = AppSupportDirectory.url().appendingPathComponent("install-media-helper.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            logger.error("cannot write the installer: \(error.localizedDescription, privacy: .public)")
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Whether the helper can pair the two streams a "best available" download may come as.
    static func hasMerger() -> Bool { merger() != nil }

    /// `ffmpeg` itself, which joins two streams and speaks HLS and DASH playlists.
    static func merger() -> URL? {
        let manager = FileManager.default
        for directory in toolSearchPath.split(separator: ":") {
            let path = "\(directory)/ffmpeg"
            if manager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    // MARK: - Process

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? ""
        environment["PATH"] = existing.isEmpty ? toolSearchPath : "\(toolSearchPath):\(existing)"
        return environment
    }

    /// Runs the helper to completion and hands back its output. Used for the short,
    /// metadata-only calls; downloads are streamed by `MediaDownloadRunner` instead.
    private static func run(tool: URL, arguments: [String]) async -> String? {
        // Spawning and draining a pipe is blocking work, and under approachable concurrency a
        // nonisolated async function runs on its caller's executor — which is the main actor
        // here. Detaching is what keeps the interface responsive while the helper thinks.
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.environment = environment()

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                logger.error("media helper failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }

            // Read before waiting: a full pipe buffer would deadlock the child.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
