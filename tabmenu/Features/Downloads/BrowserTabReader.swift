//
//  BrowserTabReader.swift
//  tabmenu
//

import AppKit
import os

nonisolated enum WebBrowser: String, CaseIterable, Sendable {
    case safari
    case chrome
    case brave
    case edge
    case arc
    case vivaldi
    case opera

    var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .arc: "company.thebrowser.Browser"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        }
    }

    /// Name AppleScript addresses the application by.
    var scriptName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .brave: "Brave Browser"
        case .edge: "Microsoft Edge"
        case .arc: "Arc"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        }
    }

    /// Everything but Safari speaks Chrome's dialect, tabs and windows included.
    var isChromium: Bool { self != .safari }

    static func matching(bundleIdentifier: String?) -> WebBrowser? {
        guard let bundleIdentifier else { return nil }
        return allCases.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// The browser a process belongs to, its helpers included.
    ///
    /// Sound does not come out of a browser itself but out of a renderer it spawned, and those
    /// carry identifiers built on the browser's own — `com.google.Chrome.helper.Renderer` and
    /// the like. Matching on the prefix covers every one of them without a list to maintain.
    static func owning(bundleIdentifier: String?) -> WebBrowser? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return allCases.first {
            bundleIdentifier == $0.bundleIdentifier
                || bundleIdentifier.hasPrefix($0.bundleIdentifier + ".")
        }
    }
}

/// The page in front of a browser.
nonisolated struct BrowserTab: Sendable, Equatable {
    let url: URL
    /// The page's own title, which is what a person would call what they are watching.
    let title: String
}

/// What came back from asking a browser what it is showing.
nonisolated enum BrowserTabResult: Sendable, Equatable {
    case tab(BrowserTab)
    /// macOS refused the Apple event. Silence here is the one failure users cannot diagnose,
    /// so it is carried back rather than swallowed.
    case notPermitted
    /// Nothing to report: no window, a blank tab, or an address that is not a web page.
    case nothing
}

/// Reads the address of the page in front.
///
/// This is the only way a native app can tell what the user is looking at — there is no API
/// for the contents of a browser tab, and none for its network traffic. It costs an Automation
/// permission per browser, which macOS asks for the first time this runs.
nonisolated enum BrowserTabReader {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "Downloads")

    /// The frontmost browser, or `nil` when the user is in another application.
    static func frontmostBrowser() -> WebBrowser? {
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return WebBrowser.matching(bundleIdentifier: bundleIdentifier)
    }

    /// Blocking: spawns `osascript`. Call it off the main thread.
    static func currentTab(in browser: WebBrowser) -> BrowserTabResult {
        let script = browser.isChromium
            ? """
            tell application "\(browser.scriptName)"
                if it is not running then return ""
                if (count of windows) is 0 then return ""
                set theTab to active tab of front window
                return (URL of theTab) & "\\n" & (title of theTab)
            end tell
            """
            : """
            tell application "\(browser.scriptName)"
                if it is not running then return ""
                if (count of documents) is 0 then return ""
                return (URL of front document) & "\\n" & (name of front document)
            end tell
            """

        let result = run(script)
        if result.isDenied { return .notPermitted }
        guard let output = result.output, !output.isEmpty else { return .nothing }

        let lines = output.components(separatedBy: "\n")
        guard let address = lines.first,
              let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return .nothing }

        // A title can contain anything, newlines included; everything after the address is it.
        let title = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return .tab(BrowserTab(url: url, title: title))
    }

    /// The browsers currently producing sound.
    ///
    /// Measured rather than guessed: Core Audio says which processes are playing, so this is the
    /// one honest answer to "is that video actually running". It is also the precondition for
    /// asking a browser anything at all — titles are not read while someone merely browses, only
    /// when sound is coming out.
    static func audibleBrowsers(in processes: [AudioProcessInfo]) -> [WebBrowser] {
        var found: [WebBrowser] = []
        for process in processes where process.isPlaying {
            guard let browser = WebBrowser.owning(bundleIdentifier: process.bundleID),
                  !found.contains(browser)
            else { continue }
            found.append(browser)
        }
        return found
    }

    /// `osascript` reports a refused Apple event as an error, and the code is the only part of
    /// it that is stable across macOS versions and interface languages.
    static func isPermissionError(_ message: String) -> Bool {
        message.contains("-1743") || message.contains("-600") || message.contains("errAEEventNotPermitted")
    }

    private static func run(_ source: String) -> (output: String?, isDenied: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            // Both pipes are drained before waiting: a full buffer on either would deadlock.
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let message = String(data: errorData, encoding: .utf8) ?? ""
            if process.terminationStatus != 0, isPermissionError(message) {
                logger.notice("automation permission refused")
                return (nil, true)
            }
            return (
                String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                false
            )
        } catch {
            logger.error("cannot read the front tab: \(error.localizedDescription, privacy: .public)")
            return (nil, false)
        }
    }
}
