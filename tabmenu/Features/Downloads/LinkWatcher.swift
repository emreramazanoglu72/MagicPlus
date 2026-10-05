//
//  LinkWatcher.swift
//  tabmenu
//

import AppKit
import Foundation

/// Notices links worth downloading, without ever looking at a page's contents.
///
/// Two sources, and neither of them is magic. Copying a link is the deliberate one: it is how
/// every download manager has worked for twenty years, and it is unambiguous — the user picked
/// that link. Watching the front tab is the ambient one, and it is the only thing a native app
/// can do about a video playing in a browser: there is no API for a tab's network traffic, so
/// the address bar is all there is to go on. That is also why it stays off until switched on
/// and why it never starts anything by itself — it offers, and the island asks.
@MainActor
final class LinkWatcher {
    /// A link worth offering. Nothing is queued until something acts on this.
    var onCandidate: ((DownloadCandidate) -> Void)?
    /// macOS refused to let this app ask a browser what it is showing. Reported once per
    /// browser: without it the feature simply appears not to work, which is the failure users
    /// cannot diagnose for themselves.
    var onAutomationDenied: ((WebBrowser) -> Void)?

    private let preferences: Preferences
    private let pasteboard: NSPasteboard
    private var clipboardTimer: Timer?
    private var browserTimer: Timer?
    private var lastChangeCount: Int
    private var lastTabURL: URL?
    /// Links already offered. Offering the same one twice is how a helpful feature becomes
    /// an interruption.
    private var offered: [URL] = []
    /// Browsers that refused the Apple event. Asking again would only mean a spawned process
    /// every few seconds for an answer that will not change until the user grants permission.
    private var denied: Set<WebBrowser> = []

    /// Copying is a deliberate act and deserves a quick response; a browser tab is polled far
    /// more gently, because each poll is an Apple event to another application.
    private static let clipboardInterval: TimeInterval = 0.7
    private static let browserInterval: TimeInterval = 2.5
    private static let memoryLimit = 40

    init(preferences: Preferences, pasteboard: NSPasteboard = .general) {
        self.preferences = preferences
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    // MARK: - Lifecycle

    func updateMonitoring() {
        stop()
        // Switching the setting off and on again is how someone retries after granting
        // permission, so the refusals are forgotten here.
        denied.removeAll()
        guard preferences.isDownloadManagerEnabled else { return }

        if preferences.grabsLinksFromClipboard {
            lastChangeCount = pasteboard.changeCount
            clipboardTimer = Timer.scheduledTimer(
                withTimeInterval: Self.clipboardInterval,
                repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkClipboard() }
            }
        }

        if preferences.watchesBrowserTabs {
            browserTimer = Timer.scheduledTimer(
                withTimeInterval: Self.browserInterval,
                repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkBrowserTab() }
            }
        }
    }

    func stop() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        browserTimer?.invalidate()
        browserTimer = nil
    }

    /// Marks a link as dealt with, so neither source offers it again.
    func remember(_ url: URL) {
        guard !offered.contains(url) else { return }
        offered.append(url)
        if offered.count > Self.memoryLimit { offered.removeFirst(offered.count - Self.memoryLimit) }
    }

    // MARK: - Sources

    /// Where a link came from, which decides how forward it is safe to be about it.
    private enum Source {
        /// Copying is on by default, so it stays conservative.
        case clipboard
        /// Watching the browser is something the user switched on deliberately.
        case browserTab
    }

    private func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let string = pasteboard.string(forType: .string) else { return }
        guard let url = Self.singleWebURL(in: string) else { return }
        consider(url, from: .clipboard)
    }

    private func checkBrowserTab() {
        guard let browser = BrowserTabReader.frontmostBrowser(), !denied.contains(browser) else { return }

        // Spawning `osascript` is blocking work, so it is detached — but only the work is. The
        // answer comes back as a value and is handled here, where this object lives.
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                BrowserTabReader.currentTab(in: browser)
            }.value
            self?.handle(result, from: browser)
        }
    }

    private func handle(_ result: BrowserTabResult, from browser: WebBrowser) {
        switch result {
        case .tab(let tab):
            handleTab(tab.url)
        case .notPermitted:
            guard denied.insert(browser).inserted else { return }
            onAutomationDenied?(browser)
        case .nothing:
            break
        }
    }

    private func handleTab(_ url: URL) {
        guard url != lastTabURL else { return }
        lastTabURL = url
        // Only two things in a browser are worth offering: a page with media on it, and a link
        // that is plainly a file. Everything else is just browsing.
        guard MediaTool.isMediaPage(url) || LinkProbe.isProbablyFile(url) else { return }
        consider(url, from: .browserTab)
    }

    /// Whether a media page should be put in front of the user.
    ///
    /// Someone who switched browser watching on asked to hear about media pages, so they hear
    /// about them even with no helper installed — the prompt then explains what is missing,
    /// which is the answer to "why did nothing happen". The clipboard is on by default and
    /// stays quiet instead: a copied video link is not a request to install anything.
    private func offersMedia(_ url: URL, from source: Source) -> Bool {
        guard MediaTool.isMediaPage(url) else { return false }
        if source == .browserTab { return true }
        return MediaTool.resolve(configuredPath: preferences.mediaToolPath) != nil
    }

    private func consider(_ url: URL, from source: Source) {
        guard !offered.contains(url) else { return }
        // Remembered before the probe, not after: the clipboard's change counter has already
        // moved on, so a link dropped here would never come back.
        remember(url)

        if offersMedia(url, from: source) {
            onCandidate?(DownloadCoordinator.mediaCandidate(for: url))
            return
        }

        Task { [weak self] in
            guard let candidate = await LinkProbe.probe(url), let self else { return }
            onCandidate?(candidate)
        }
    }

    // MARK: - Parsing

    /// A clipboard entry counts as a link only when the whole of it is one. Copied prose that
    /// happens to mention a URL is not a request to download anything.
    static func singleWebURL(in string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 2048,
              !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }
}
