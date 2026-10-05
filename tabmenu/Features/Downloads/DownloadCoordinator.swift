//
//  DownloadCoordinator.swift
//  tabmenu
//

import AppKit
import Observation

/// Ties the download queue to the rest of the app: the watcher that notices links, the prompt
/// that asks about them, and the island that reports on them.
///
/// The order is always the same and it is the point of the whole feature — notice, offer,
/// confirm, transfer. Nothing between "noticed a link" and "the user said yes" writes a byte.
@Observable
@MainActor
final class DownloadCoordinator {
    @ObservationIgnored let store: DownloadStore
    @ObservationIgnored let prompt: DownloadPromptController
    /// The loopback endpoint the browser extension talks to.
    @ObservationIgnored let bridge: BrowserBridge

    /// The browser macOS would not let this app ask. Shown in Settings, because a permission
    /// the user has to grant elsewhere is not something to fail silently over.
    private(set) var automationDeniedBrowser: WebBrowser?

    /// Set by the composition root so the island can speak for the queue.
    @ObservationIgnored var onAnnounce: ((NotchActivity) -> Void)?
    /// Grows the island into a card asking about a link. A download is a decision, and a capsule
    /// is not enough room to make one in.
    @ObservationIgnored var onOffer: ((DownloadOffer) -> Void)?
    /// Called with a file name the queue is about to write, so the shelf's folder watcher
    /// does not report it as an arrival from elsewhere.
    @ObservationIgnored var onWillPlaceFile: ((String) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let watcher: LinkWatcher
    /// The link the island is currently offering. Cleared when it is taken up or goes stale.
    @ObservationIgnored private var pending: DownloadCandidate?
    /// Pages already offered, so a player reaching for a new segment does not ask again.
    @ObservationIgnored private var offeredPages: [URL] = []
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// How long a capsule's offer stands. Slightly longer than the capsule itself, so a click
    /// that lands as it collapses still works.
    private static let offerLifetime: Duration = .seconds(12)

    /// - Parameter store: Injected by tests so they never touch the real queue.
    init(
        preferences: Preferences,
        frontmostTracker: FrontmostApplicationTracker,
        store injectedStore: DownloadStore? = nil
    ) {
        self.preferences = preferences
        let store = injectedStore ?? DownloadStore(preferences: preferences)
        self.store = store
        self.watcher = LinkWatcher(preferences: preferences)
        self.bridge = BrowserBridge(preferences: preferences)
        self.prompt = DownloadPromptController(
            store: store,
            preferences: preferences,
            frontmostTracker: frontmostTracker
        )

        store.onFinished = { [weak self] item in
            self?.onAnnounce?(.download(name: item.fileName))
        }
        store.onFailed = { [weak self] item in
            self?.onAnnounce?(.downloadFailed(name: item.fileName))
        }
        store.onWillPlaceFile = { [weak self] name in
            self?.onWillPlaceFile?(name)
        }
        watcher.onCandidate = { [weak self] candidate in
            self?.offer(candidate)
        }
        watcher.onAutomationDenied = { [weak self] browser in
            self?.automationDeniedBrowser = browser
        }
        prompt.onConfirm = { [weak self] request in
            self?.enqueue(request)
        }
        bridge.onCatch = { [weak self] caught in
            self?.accept(caught)
        }
        bridge.onMedia = { [weak self] media in
            self?.offerMedia(media)
        }
    }

    // MARK: - Lifecycle

    func updateMonitoring() {
        automationDeniedBrowser = nil
        watcher.updateMonitoring()
        bridge.updateMonitoring()
    }

    // MARK: - Offers

    /// Puts a link in front of the user. It is never started here.
    func offer(_ candidate: DownloadCandidate) {
        guard preferences.isDownloadManagerEnabled, !store.contains(candidate.url) else { return }

        pending = candidate
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.offerLifetime)
            guard !Task.isCancelled else { return }
            self?.pending = nil
        }

        onOffer?(DownloadOffer(candidate: candidate))
    }

    /// The card was taken up: open the prompt for whatever it was offering.
    func showPending() {
        guard let pending else { return }
        self.pending = nil
        expiryTask?.cancel()
        prompt.show(pending)
    }

    /// The guess was wrong, or there was nothing to guess from. Opens the prompt with an address
    /// field to type into, filled in from the clipboard when there is a link on it.
    func showManualEntry() {
        pending = nil
        expiryTask?.cancel()
        let clipboard = NSPasteboard.general.string(forType: .string)
            .flatMap(LinkWatcher.singleWebURL(in:))
        prompt.showManualEntry(prefilled: clipboard)
    }

    /// A link dropped straight onto the island. Dropping is already an explicit act, so this
    /// goes to the prompt rather than to a capsule that has to be noticed first.
    func promptForLink(_ url: URL) {
        guard preferences.isDownloadManagerEnabled else { return }
        watcher.remember(url)

        if let immediate = Self.immediateCandidate(for: url) {
            prompt.show(immediate)
            return
        }

        Task { [weak self] in
            let probed = await LinkProbe.probe(url)
            guard let self else { return }
            // A probe that came back with nothing is still a link the user aimed at this
            // window, so it is offered as a plain file rather than silently dropped.
            prompt.show(probed ?? DownloadCandidate(
                url: url,
                fileName: LinkProbe.fileName(from: nil, url: url),
                kind: LinkProbe.kind(forExtension: url.pathExtension, mimeType: nil),
                byteSize: nil,
                isResumable: false,
                transport: .http,
                title: nil
            ))
        }
    }

    /// What a deliberately requested link is offered as without asking the network first.
    ///
    /// A media page is a media page whether or not the helper is installed: probing one would
    /// come back with the page's markup, and downloading that as though it were the video is
    /// worse than a prompt that explains what is missing. `nil` means the link has to be
    /// probed before anything can be said about it.
    static func immediateCandidate(for url: URL) -> DownloadCandidate? {
        MediaTool.isMediaPage(url) ? mediaCandidate(for: url) : nil
    }

    /// A page whose media the helper could fetch. The name is a placeholder until the helper
    /// reports the real title.
    static func mediaCandidate(for url: URL) -> DownloadCandidate {
        // Until the helper reports a title the capsule can only name the site, and "www." is
        // three syllables of nothing in a space that has room for very little.
        let host = url.host() ?? "video"
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        return DownloadCandidate(
            url: url,
            fileName: LinkProbe.sanitize(site),
            kind: .video,
            byteSize: nil,
            isResumable: true,
            transport: .mediaTool,
            title: nil
        )
    }

    // MARK: - Browser hand-off

    /// A download the extension passed over.
    ///
    /// This one does not ask. The browser had already started it — the user clicked a link and
    /// is owed the file — so a prompt here would be a second question about a decision already
    /// made, and closing it by accident would lose the download outright. It goes straight into
    /// the queue with the browser's own cookies and referer, which is what gets it past the
    /// signed links and session checks that make a bare URL answer 403.
    func accept(_ caught: BridgeCatch) {
        guard preferences.isDownloadManagerEnabled else { return }
        watcher.remember(caught.url)

        let name = caught.fileName ?? LinkProbe.fileName(from: nil, url: caught.url)
        let candidate = DownloadCandidate(
            url: caught.url,
            fileName: name,
            kind: LinkProbe.kind(
                forExtension: (name as NSString).pathExtension,
                mimeType: caught.mimeType
            ),
            byteSize: caught.byteSize,
            isResumable: false,
            transport: .http,
            title: nil
        )

        let item = store.add(candidate, folder: nil, headers: caught.headers)
        onAnnounce?(.downloadStarted(name: item.fileName))
    }

    /// Menu bar action: take whatever link is on the clipboard.
    func promptForClipboardLink() {
        guard let string = NSPasteboard.general.string(forType: .string),
              let url = LinkWatcher.singleWebURL(in: string)
        else {
            NSSound.beep()
            return
        }
        promptForLink(url)
    }

    private func enqueue(_ request: DownloadRequest) {
        var candidate = request.candidate

        // A stream picked off the page replaces the link entirely: it is the URL the player was
        // using, and whether it needs joining decides how the queue fetches it.
        if let option = request.streamOption {
            candidate.url = option.url
            candidate.byteSize = option.byteSize
            candidate.transport = option.isPlaylist
                ? .playlist
                : (option.needsMerge ? .streamMerge : .http)
            candidate.kind = option.audioURL == nil && option.fileExtension == "m4a" ? .audio : .video
        }

        let item = store.add(
            candidate,
            fileName: request.fileName,
            folder: request.folder,
            quality: request.quality,
            headers: candidate.headers,
            secondaryURL: request.streamOption?.audioURL
        )
        onAnnounce?(.downloadStarted(name: item.fileName))
    }

    /// A page turned out to be playing something.
    ///
    /// The formats here came out of the page's own requests, already signed by the site's own
    /// JavaScript, which is why this path needs no extractor and no helper — the same reason IDM
    /// has never shipped one. What it cannot do is offer a quality the page never asked for.
    func offerMedia(_ media: SniffedMedia) {
        guard preferences.isDownloadManagerEnabled else { return }
        // One offer per page, not one per stream the player reaches for.
        guard !offeredPages.contains(media.pageURL) else { return }

        let name = media.title.isEmpty ? (media.pageURL.host() ?? "video") : media.title

        // A page the helper knows is better served by it, and this is not a close call. Watching
        // requests only ever finds the stream the player happened to fetch — one quality, and on
        // YouTube increasingly not even that, because its newer delivery is a POST whose URL
        // cannot be replayed. The helper lists every format the site has.
        if MediaTool.isMediaPage(media.pageURL),
           MediaTool.resolve(configuredPath: preferences.mediaToolPath) != nil {
            remember(media.pageURL)
            var candidate = Self.mediaCandidate(for: media.pageURL)
            candidate.fileName = LinkProbe.sanitize(name)
            candidate.title = media.title.isEmpty ? nil : media.title
            candidate.headers = media.headers
            offer(candidate)
            return
        }

        let options = media.options(hasFfmpeg: MediaTool.hasMerger())
        guard !options.isEmpty else { return }
        remember(media.pageURL)

        offer(DownloadCandidate(
            url: media.pageURL,
            fileName: LinkProbe.sanitize(name),
            kind: .video,
            byteSize: options.first?.byteSize,
            isResumable: false,
            transport: .http,
            title: media.title.isEmpty ? nil : media.title,
            streamOptions: options,
            headers: media.headers
        ))
    }

    private func remember(_ pageURL: URL) {
        offeredPages.append(pageURL)
        if offeredPages.count > 20 { offeredPages.removeFirst(offeredPages.count - 20) }
    }
}
