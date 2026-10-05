//
//  DownloadTests.swift
//  tabmenuTests
//

import Testing
import AVFoundation
import Foundation
@testable import tabmenu

@Suite("Download names")
struct DownloadNameTests {
    /// Both forms turn up in the wild, and the encoded one is the only way a non-ASCII name
    /// survives the trip.
    @Test func contentDispositionYieldsTheServerSName() {
        #expect(LinkProbe.fileName(fromDisposition: "attachment; filename=\"report.pdf\"") == "report.pdf")
        #expect(LinkProbe.fileName(fromDisposition: "attachment; filename=report.pdf") == "report.pdf")
        #expect(
            LinkProbe.fileName(fromDisposition: "attachment; filename*=UTF-8''rapor%20%C3%B6zet.pdf")
                == "rapor özet.pdf"
        )
        #expect(LinkProbe.fileName(fromDisposition: "inline") == nil)
    }

    /// A name from a server is untrusted input. This is the one place a download manager can
    /// be talked into writing outside the folder it was pointed at.
    @Test func namesCannotEscapeTheDownloadFolder() {
        #expect(!LinkProbe.sanitize("../../.zshrc").contains(".."))
        #expect(!LinkProbe.sanitize("/etc/passwd").hasPrefix("/"))
        #expect(LinkProbe.sanitize("a/b/c.zip") == "a-b-c.zip")
        #expect(LinkProbe.sanitize("   ") == "download")
        #expect(LinkProbe.sanitize(String(repeating: "x", count: 400)).count <= 200)
    }

    /// Without a `Content-Disposition` the path is all there is, and it arrives encoded.
    @Test func theUrlIsTheFallbackName() {
        #expect(LinkProbe.fileName(from: nil, url: URL(string: "https://x.dev/a/b/setup%20file.dmg")!) == "setup file.dmg")
        #expect(LinkProbe.fileName(from: nil, url: URL(string: "https://x.dev/file.zip?token=1")!) == "file.zip")
        #expect(LinkProbe.fileName(from: nil, url: URL(string: "https://example.com/")!) == "example-com")
    }
}

@Suite("Download classification")
struct DownloadClassificationTests {
    @Test func extensionsDecideTheKind() {
        #expect(LinkProbe.kind(forExtension: "zip", mimeType: nil) == .archive)
        #expect(LinkProbe.kind(forExtension: "DMG", mimeType: nil) == .application)
        #expect(LinkProbe.kind(forExtension: "mkv", mimeType: nil) == .video)
        #expect(LinkProbe.kind(forExtension: "flac", mimeType: nil) == .audio)
        #expect(LinkProbe.kind(forExtension: "pdf", mimeType: nil) == .document)
    }

    /// Download endpoints routinely have no extension at all, so the type header is the only
    /// thing left to go on.
    @Test func theMimeTypeDecidesWhenTheExtensionCannot() {
        #expect(LinkProbe.kind(forExtension: "", mimeType: "video/mp4") == .video)
        #expect(LinkProbe.kind(forExtension: "php", mimeType: "application/zip") == .archive)
        #expect(LinkProbe.kind(forExtension: "", mimeType: nil) == .other)
    }

    @Test func onlyFileLikeLinksAreOfferedWithoutAProbe() {
        #expect(LinkProbe.isProbablyFile(URL(string: "https://x.dev/app.dmg")!))
        #expect(!LinkProbe.isProbablyFile(URL(string: "https://x.dev/blog/post")!))
    }
}

@Suite("Link grabbing")
struct LinkGrabbingTests {
    /// Copied prose that happens to mention an address is not a request to download it.
    @Test func onlyAClipboardThatIsEntirelyALinkCounts() {
        #expect(LinkWatcher.singleWebURL(in: "https://x.dev/a.zip") != nil)
        #expect(LinkWatcher.singleWebURL(in: "  https://x.dev/a.zip \n") != nil)
        #expect(LinkWatcher.singleWebURL(in: "see https://x.dev/a.zip for details") == nil)
        #expect(LinkWatcher.singleWebURL(in: "ftp://x.dev/a.zip") == nil)
        #expect(LinkWatcher.singleWebURL(in: "file:///Users/me/a.zip") == nil)
        #expect(LinkWatcher.singleWebURL(in: "") == nil)
    }

    /// A site's front page is not a video, and offering to download one would be noise.
    @Test func onlyPagesThatIdentifyAVideoCount() {
        #expect(MediaTool.isMediaPage(URL(string: "https://www.youtube.com/watch?v=abc")!))
        #expect(MediaTool.isMediaPage(URL(string: "https://youtube.com/shorts/abc")!))
        #expect(MediaTool.isMediaPage(URL(string: "https://youtu.be/abc")!))
        #expect(!MediaTool.isMediaPage(URL(string: "https://www.youtube.com/")!))
        #expect(!MediaTool.isMediaPage(URL(string: "https://www.youtube.com/feed/subscriptions")!))
        #expect(!MediaTool.isMediaPage(URL(string: "https://example.com/watch?v=abc")!))
    }
}

@Suite("Media helper")
struct MediaHelperTests {
    /// A refused Apple event is the one failure the user cannot diagnose, so it has to be told
    /// apart from "there is no tab". The numeric code is the only part of the message that is
    /// stable across macOS versions and interface languages.
    @Test func aRefusedAppleEventIsRecognisedInAnyLanguage() {
        #expect(BrowserTabReader.isPermissionError(
            "execution error: Not authorized to send Apple events to Google Chrome. (-1743)"
        ))
        #expect(BrowserTabReader.isPermissionError(
            "yürütme hatası: Google Chrome uygulamasına Apple olayları gönderme yetkisi yok. (-1743)"
        ))
        #expect(!BrowserTabReader.isPermissionError(
            "execution error: Google Chrome got an error: Can't get window 1. (-1728)"
        ))
        #expect(!BrowserTabReader.isPermissionError(""))
    }

    /// Separate video and audio come first wherever they can be joined. This is the bug that
    /// made every YouTube download fail: asking for the single-file "progressive" format gets
    /// a 403 from YouTube on most videos, while the same video downloads fine as two streams.
    @Test func videoQualitiesAskForSeparateStreamsWhenTheyCanBeJoined() {
        for quality in [MediaQuality.p1080, .p720, .p480] {
            let merging = quality.selector(canMerge: true)
            #expect(merging.hasPrefix("bv*["), "\(quality.rawValue) would ask for a progressive format first")
            #expect(merging.contains("+ba"))
            // The single file is still there as a fallback, for a site that only offers one.
            #expect(merging.contains("/b["))
            #expect(quality.needsMerger)
        }
        #expect(MediaQuality.best.selector(canMerge: true) == "bv*+ba/b")
    }

    /// With no `ffmpeg` there is nothing to join two streams with, so the single file is all
    /// that can be asked for — and the prompt says as much before the download starts.
    @Test func withoutAMergerOnlySingleFilesCanBeAskedFor() {
        for quality in [MediaQuality.best, .p1080, .p720, .p480] {
            let plain = quality.selector(canMerge: false)
            #expect(!plain.contains("+ba"), "\(quality.rawValue) asks for a merge it cannot do")
            #expect(plain.hasPrefix("b"))
        }
    }

    /// Audio arrives as its own stream either way, which is why it is the one preset that
    /// works on a machine with no `ffmpeg` at all.
    @Test func audioNeverNeedsAMerger() {
        #expect(!MediaQuality.audio.needsMerger)
        #expect(MediaQuality.audio.selector(canMerge: false) == MediaQuality.audio.selector(canMerge: true))
        #expect(MediaQuality.audio.selector(canMerge: false).contains("ba"))
    }

    /// The argument list is the whole contract with the helper, and two of its entries are
    /// load-bearing in ways that are invisible until they are missing: `--print` implies
    /// `--quiet`, which silences progress unless `--progress` puts it back.
    @Test func theHelperIsAskedForProgressItWouldOtherwiseNotReport() {
        let arguments = MediaDownloadRunner.arguments(
            url: URL(string: "https://www.youtube.com/watch?v=abc")!,
            quality: .p720,
            folder: URL(fileURLWithPath: "/tmp/dl"),
            canMerge: true,
            cookies: .none
        )
        #expect(arguments.contains("--progress"))
        #expect(arguments.contains("--newline"))
        #expect(arguments.contains("--continue"))
        #expect(arguments.contains("bv*[height<=?720]+ba/b[height<=?720]/b"))
        #expect(arguments.last == "https://www.youtube.com/watch?v=abc")
        // Non-ASCII titles stay legible; this flag would have mangled them.
        #expect(!arguments.contains("--restrict-filenames"))
        #expect(!arguments.contains("--cookies-from-browser"))
    }

    /// Cookies are the documented way past a site that blocks a stream URL partway through,
    /// and they are only ever passed when the user has picked a browser.
    @Test func cookiesAreOnlyPassedWhenChosen() {
        func arguments(_ cookies: MediaCookieSource) -> [String] {
            MediaDownloadRunner.arguments(
                url: URL(string: "https://www.youtube.com/watch?v=abc")!,
                quality: .best,
                folder: URL(fileURLWithPath: "/tmp/dl"),
                canMerge: true,
                cookies: cookies
            )
        }

        #expect(MediaCookieSource.none.helperName == nil)
        #expect(MediaCookieSource.chrome.helperName == "chrome")

        let withCookies = arguments(.chrome)
        #expect(withCookies.contains("--cookies-from-browser"))
        #expect(withCookies.contains("chrome"))
        #expect(!arguments(.none).contains("--cookies-from-browser"))
    }

    /// A 403 is the site refusing a stream URL it just issued. The helper's own words explain
    /// nothing a user could act on, so the message names whichever setting would fix it.
    @Test func aBlockedDownloadPointsAtTheSettingThatFixesIt() {
        let raw = "ERROR: unable to download video data: HTTP Error 403: Forbidden"

        let noCookies = MediaDownloadRunner.reason(from: raw, status: 1, canMerge: true, usesCookies: false)
        #expect(noCookies.localizedCaseInsensitiveContains("cookie") || noCookies.contains("çerez"))

        let noMerger = MediaDownloadRunner.reason(from: raw, status: 1, canMerge: false, usesCookies: true)
        #expect(noMerger.localizedCaseInsensitiveContains("ffmpeg"))

        // Everything already in place: the helper's own words are all there is to report.
        let exhausted = MediaDownloadRunner.reason(from: raw, status: 1, canMerge: true, usesCookies: true)
        #expect(exhausted.contains("403"))
        #expect(!exhausted.contains("ERROR: "))

        // An unrelated failure is passed through, not reinterpreted.
        let private_ = MediaDownloadRunner.reason(
            from: "ERROR: Video unavailable. This video is private",
            status: 1, canMerge: true, usesCookies: false
        )
        #expect(private_.contains("private"))
    }

    /// A video and its audio are two transfers, each counted from zero by the helper. Reported
    /// raw, the bar would fill, snap back to nothing and fill again.
    @Test func twoStreamsAddUpInsteadOfStartingOver() {
        var accumulator = MediaDownloadRunner.ProgressAccumulator()

        func push(_ received: Int64, _ total: Int64?) -> (received: Int64, total: Int64?) {
            accumulator.push(.init(received: received, total: total, speed: nil))
        }

        #expect(push(1_000, 10_000) == (1_000, 10_000))
        #expect(push(10_000, 10_000) == (10_000, 10_000))

        // Audio starts, so the count drops — and the running total has to keep climbing.
        let first = push(500, 4_000)
        #expect(first.received == 10_500)
        #expect(first.total == 14_000)

        let last = push(4_000, 4_000)
        #expect(last.received == 14_000)
        #expect(last.total == 14_000)
    }

    /// The helper prints `NA` for anything it does not know yet, which is most of the first
    /// line of every download.
    @Test func progressLinesSurviveMissingFields() {
        let full = MediaDownloadRunner.parseProgress("MP-PROGRESS 1048576 20971520 20971520 524288.0")
        #expect(full?.received == 1_048_576)
        #expect(full?.total == 20_971_520)
        #expect(full?.speed == 524_288)

        let estimated = MediaDownloadRunner.parseProgress("MP-PROGRESS 512 NA 4096 NA")
        #expect(estimated?.total == 4096)
        #expect(estimated?.speed == nil)

        let unknown = MediaDownloadRunner.parseProgress("MP-PROGRESS 512 NA NA NA")
        #expect(unknown?.total == nil)
        #expect(MediaDownloadRunner.parseProgress("[download] 12% of 4MiB") == nil)
    }
}

@Suite("Download items")
struct DownloadItemTests {
    private func item(
        total: Int64? = 1000,
        received: Int64 = 500,
        state: DownloadState = .running
    ) -> DownloadItem {
        var item = DownloadItem(
            url: URL(string: "https://x.dev/a.zip")!,
            fileName: "a.zip",
            folder: URL(fileURLWithPath: "/tmp"),
            kind: .archive,
            totalBytes: total,
            receivedBytes: received,
            state: state
        )
        item.bytesPerSecond = 100
        return item
    }

    /// A bar that guesses is worse than no bar: a server that will not say how big the body
    /// is has to show as indeterminate all the way through.
    @Test func progressIsAbsentWhenTheSizeIs() {
        #expect(item().progress == 0.5)
        #expect(item(total: nil).progress == nil)
        #expect(item(total: 0).progress == nil)
    }

    /// The partial file must carry an extension the shelf's folder watcher ignores, or every
    /// download would announce itself the moment it started.
    @Test func partialFilesAreNotAnnouncedAsArrivals() {
        let partial = item().partURL
        #expect(partial.pathExtension == "part")
        #expect(partial.deletingPathExtension().lastPathComponent == "a.zip")
    }

    /// Every state has something to say about itself in the queue.
    @Test func everyStateExplainsItself() {
        for state in [DownloadState.queued, .running, .paused, .completed, .failed] {
            #expect(!item(state: state).statusLine.isEmpty, "\(state.rawValue) says nothing")
        }
    }

    /// A speed read back off disk would be a number that was true minutes ago, so it is the
    /// one field that is deliberately not persisted.
    @Test func speedDoesNotSurviveARelaunch() throws {
        let encoded = try JSONEncoder().encode(item())
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: encoded)
        #expect(decoded.bytesPerSecond == 0)
        #expect(decoded.receivedBytes == 500)
        #expect(decoded.fileName == "a.zip")
    }

    @Test func remainingTimeNeedsBothARateAndASize() {
        var running = item(total: 2000, received: 1000)
        running.bytesPerSecond = 500 * 1024
        #expect(running.remainingSeconds != nil)
        #expect(item(total: nil).remainingSeconds == nil)
        #expect(item(state: .paused).remainingSeconds == nil)
    }
}

@MainActor
@Suite("Download queue")
struct DownloadQueueTests {
    private func makeStore() -> DownloadStore {
        let defaults = UserDefaults(suiteName: "downloads.tests") ?? .standard
        defaults.removePersistentDomain(forName: "downloads.tests")
        let storage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downloads-\(UUID().uuidString).json")
        return DownloadStore(preferences: Preferences(defaults: defaults), storageURL: storage)
    }

    private var candidate: DownloadCandidate {
        DownloadCandidate(
            url: URL(string: "https://x.dev/a.zip")!,
            fileName: "a.zip",
            kind: .archive,
            byteSize: 2000,
            isResumable: true,
            transport: .http,
            title: nil
        )
    }

    /// Nothing is offered or queued twice, whichever source noticed the link.
    @Test func theSameLinkIsNotQueuedTwice() {
        let store = makeStore()
        store.add(candidate, startsImmediately: false)
        #expect(store.contains(candidate.url))
        #expect(store.items.count == 1)
    }

    /// Parking an entry must not open a connection, which is also what makes the queue
    /// testable without a network.
    @Test func aParkedEntryDoesNotStart() {
        let store = makeStore()
        let item = store.add(candidate, startsImmediately: false)
        #expect(item.state == .paused)
        #expect(store.runningCount == 0)
        #expect(store.hasActivity == false)
    }

    /// A partial file is the queue's own scratch space, so dropping the entry takes it with
    /// it. A finished file belongs to the user and is left exactly where it is.
    @Test func removingAParkedEntryDiscardsItsPartialFile() throws {
        let store = makeStore()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let item = store.add(candidate, folder: folder, startsImmediately: false)
        try Data("half".utf8).write(to: item.partURL)

        store.remove(item.id)
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: item.partURL.path))
        try? FileManager.default.removeItem(at: folder)
    }

    /// The ring on the resting island sums what is in flight, and stays absent while nothing
    /// in flight knows its own size.
    @Test func theRingSumsWhatIsInFlight() {
        func item(total: Int64?, received: Int64, state: DownloadState) -> DownloadItem {
            DownloadItem(
                url: URL(string: "https://x.dev/\(received).zip")!,
                fileName: "\(received).zip",
                folder: URL(fileURLWithPath: "/tmp"),
                kind: .archive,
                totalBytes: total,
                receivedBytes: received,
                state: state
            )
        }

        #expect(DownloadStore.aggregateProgress(of: [
            item(total: 1000, received: 250, state: .running),
            item(total: 1000, received: 750, state: .queued)
        ]) == 0.5)

        // A finished download is not "in flight" and must not hold the ring at 100%.
        #expect(DownloadStore.aggregateProgress(of: [
            item(total: 1000, received: 1000, state: .completed)
        ]) == nil)

        #expect(DownloadStore.aggregateProgress(of: [
            item(total: nil, received: 500, state: .running)
        ]) == nil)
        #expect(DownloadStore.aggregateProgress(of: []) == nil)
    }

    /// Both halves of the finishing move come from the name the transfer has been writing
    /// under. Deriving the source after choosing a numbered destination would have it look
    /// for a partial file that never existed.
    @Test func finishingMovesThePartialFileItActuallyWrote() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let item = DownloadItem(
            url: URL(string: "https://x.dev/payload.bin")!,
            fileName: "payload.bin",
            folder: folder,
            kind: .other
        )

        let first = DownloadStore.finalMove(for: item)
        #expect(first.from.lastPathComponent == "payload.bin.part")
        #expect(first.to.lastPathComponent == "payload.bin")

        // With the name already taken, the destination shifts but the source must not.
        try Data("existing".utf8).write(to: folder.appendingPathComponent("payload.bin"))
        let second = DownloadStore.finalMove(for: item)
        #expect(second.from.lastPathComponent == "payload.bin.part")
        #expect(second.to.lastPathComponent == "payload (2).bin")

        var extensionless = item
        extensionless.fileName = "payload"
        try Data("existing".utf8).write(to: folder.appendingPathComponent("payload"))
        #expect(DownloadStore.finalMove(for: extensionless).to.lastPathComponent == "payload (2)")
    }

    /// Sorting is off by default, so a download lands where the user expects it and not in a
    /// folder MagicPlus invented.
    @Test func kindFoldersOnlyAppearWhenAskedFor() {
        let store = makeStore()
        #expect(store.folder(for: .archive) == store.downloadFolder)
    }
}

@MainActor
@Suite("Download offers")
struct DownloadOfferTests {
    private func makeCoordinator() -> (DownloadCoordinator, DownloadStore, Preferences) {
        let defaults = UserDefaults(suiteName: "downloads.offers") ?? .standard
        defaults.removePersistentDomain(forName: "downloads.offers")
        let preferences = Preferences(defaults: defaults)
        let storage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offers-\(UUID().uuidString).json")
        let store = DownloadStore(preferences: preferences, storageURL: storage)
        let coordinator = DownloadCoordinator(
            preferences: preferences,
            frontmostTracker: FrontmostApplicationTracker(),
            store: store
        )
        return (coordinator, store, preferences)
    }

    private var candidate: DownloadCandidate {
        DownloadCandidate(
            url: URL(string: "https://x.dev/a.zip")!,
            fileName: "a.zip",
            kind: .archive,
            byteSize: 2000,
            isResumable: true,
            transport: .http,
            title: nil
        )
    }

    /// The contract the whole feature rests on: noticing a link asks about it and nothing more.
    /// Not a byte is written until the question is answered.
    @Test func offeringALinkOnlyAsksAboutIt() {
        let (coordinator, store, _) = makeCoordinator()
        var offers: [DownloadOffer] = []
        coordinator.onOffer = { offers.append($0) }

        coordinator.offer(candidate)

        #expect(store.items.isEmpty)
        #expect(offers.count == 1)
        #expect(offers.first?.title == "a.zip")
        #expect(offers.first?.isMedia == false)
        #expect(offers.first?.detail == Format.bytes(2000))
    }

    /// A media page is offered under its own title once the helper has resolved one, and is
    /// flagged so the capsule shows it is a video rather than a file.
    @Test func aMediaOfferSaysSo() {
        let (coordinator, _, _) = makeCoordinator()
        var offers: [DownloadOffer] = []
        coordinator.onOffer = { offers.append($0) }

        var media = candidate
        media.transport = .mediaTool
        media.title = "Some Video"
        coordinator.offer(media)

        #expect(offers.first?.title == "Some Video")
        #expect(offers.first?.isMedia == true)
    }

    /// A media page must never be routed down the plain HTTP path: probing a YouTube page
    /// returns its markup, and offering that as the video is worse than saying what is
    /// missing. Whether the helper is installed does not change what the link *is*.
    @Test func aMediaPageIsNeverOfferedAsAPlainFile() throws {
        let media = try #require(DownloadCoordinator.immediateCandidate(
            for: URL(string: "https://www.youtube.com/watch?v=NIVS1B6w77w")!
        ))
        #expect(media.transport == .mediaTool)
        #expect(media.kind == .video)

        // An ordinary link has nothing to say until it has been probed.
        #expect(DownloadCoordinator.immediateCandidate(for: URL(string: "https://x.dev/a.zip")!) == nil)
        #expect(DownloadCoordinator.immediateCandidate(for: URL(string: "https://x.dev/blog")!) == nil)
    }

    /// Something already in the queue is not offered again, whichever source noticed it.
    @Test func aLinkAlreadyQueuedIsNotOfferedAgain() {
        let (coordinator, store, _) = makeCoordinator()
        var offers: [DownloadOffer] = []
        coordinator.onOffer = { offers.append($0) }

        store.add(candidate, startsImmediately: false)
        coordinator.offer(candidate)
        #expect(offers.isEmpty)
    }

    /// With the feature switched off it stays out of the way entirely.
    @Test func nothingIsOfferedWhileTheFeatureIsOff() {
        let (coordinator, _, preferences) = makeCoordinator()
        var offers: [DownloadOffer] = []
        coordinator.onOffer = { offers.append($0) }

        preferences.isDownloadManagerEnabled = false
        coordinator.offer(candidate)
        #expect(offers.isEmpty)
    }
}

@Suite("Browser bridge protocol")
struct BridgeProtocolTests {
    private func parse(_ text: String) -> HTTPRequestParser.Outcome {
        var parser = HTTPRequestParser()
        parser.append(Data(text.utf8))
        return parser.next()
    }

    @Test func aWholeRequestIsParsed() throws {
        let outcome = parse("""
        POST /catch?x=1 HTTP/1.1\r
        Host: 127.0.0.1:27717\r
        Origin: chrome-extension://abcdef\r
        Authorization: Bearer sekret\r
        Content-Type: application/json\r
        Content-Length: 13\r
        \r
        {"url":"a"}
        """ + "ab")

        guard case .request(let request) = outcome else {
            Issue.record("did not parse: \(outcome)")
            return
        }
        #expect(request.method == "POST")
        // The query is dropped, so one route cannot be reached by two different strings.
        #expect(request.path == "/catch")
        #expect(request.bearerToken == "sekret")
        #expect(request.origin == "chrome-extension://abcdef")
        // Header case is not significant and callers should not have to remember that.
        #expect(request.header("CONTENT-TYPE") == "application/json")
        #expect(request.body.count == 13)
    }

    /// TCP hands over whatever it has, which is not the shape of what was sent.
    @Test func aRequestSplitAcrossPacketsIsAssembled() {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /catch HTTP/1.1\r\nContent-Length: 5\r".utf8))
        #expect(parser.next() == .needsMoreData)

        parser.append(Data("\n\r\nab".utf8))
        #expect(parser.next() == .needsMoreData)

        parser.append(Data("cde".utf8))
        guard case .request(let request) = parser.next() else {
            Issue.record("still not complete")
            return
        }
        #expect(String(data: request.body, encoding: .utf8) == "abcde")
    }

    /// A body this large is not one of ours, and buffering it would be someone else's idea.
    @Test func anOversizedRequestIsRefusedRatherThanBuffered() {
        let outcome = parse("POST /catch HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")
        #expect(outcome == .failure(status: 413, message: "body too large"))
        #expect(parse("nonsense\r\n\r\n") == .failure(status: 400, message: "malformed request line"))
    }

    /// The origin check is what closes the obvious attack on a local port: a page on the open
    /// web cannot mint an extension origin, and the browser will not let it lie about one.
    @Test func onlyExtensionOriginsMayAskForATokenAtAll() {
        #expect(BrowserBridge.extensionOrigin("chrome-extension://abc") == "chrome-extension://abc")
        #expect(BrowserBridge.extensionOrigin("moz-extension://abc") != nil)
        #expect(BrowserBridge.extensionOrigin("safari-web-extension://abc") != nil)
        #expect(BrowserBridge.extensionOrigin("https://evil.example") == nil)
        #expect(BrowserBridge.extensionOrigin("http://127.0.0.1:27717") == nil)
        #expect(BrowserBridge.extensionOrigin(nil) == nil)
    }

    /// Compared without an early exit, so how long the answer takes says nothing about how much
    /// of the token was right.
    @Test func tokensAreComparedWholeOrNotAtAll() {
        #expect(BrowserBridge.tokensMatch("abc123", "abc123"))
        #expect(!BrowserBridge.tokensMatch("abc123", "abc124"))
        #expect(!BrowserBridge.tokensMatch("abc123", "abc1234"))
        #expect(!BrowserBridge.tokensMatch("", ""))
    }

    /// A browser reports the full path it would have written to, and it is untrusted text: the
    /// leaf is all that is ours to use.
    @Test func onlyTheLeafOfABrowserSPathIsUsed() {
        #expect(BrowserBridge.leafName("/Users/me/Downloads/report.pdf") == "report.pdf")
        #expect(BrowserBridge.leafName("../../.zshrc") == ".zshrc")
        #expect(BrowserBridge.leafName("report.pdf") == "report.pdf")
    }

    @Test func sizesArriveAsNumbersOrStringsOrNotAtAll() {
        #expect(BrowserBridge.byteSize(1_048_576) == 1_048_576)
        #expect(BrowserBridge.byteSize("2048") == 2048)
        #expect(BrowserBridge.byteSize(0) == nil)
        #expect(BrowserBridge.byteSize(nil) == nil)
        #expect(BrowserBridge.byteSize("many") == nil)
    }

    /// The response is read by a browser, so only an extension origin may ever be echoed back:
    /// a wildcard would let any page on the web read what this port says.
    @Test func onlyTheGivenOriginIsEchoedBack() {
        let allowed = HTTPResponse.json(["a": 1], origin: "chrome-extension://abc").wireFormat
        let text = String(data: allowed, encoding: .utf8) ?? ""
        #expect(text.contains("Access-Control-Allow-Origin: chrome-extension://abc"))
        #expect(text.contains("Connection: close"))

        let anonymous = String(data: HTTPResponse.json(["a": 1]).wireFormat, encoding: .utf8) ?? ""
        #expect(!anonymous.contains("Access-Control-Allow-Origin"))
    }

    /// The context is the entire reason for the extension: cookies above all.
    @Test func aCaughtDownloadCarriesTheBrowserSContext() {
        let caught = BridgeCatch(
            url: URL(string: "https://x.dev/a.zip")!,
            fileName: "a.zip",
            mimeType: "application/zip",
            byteSize: 100,
            referrer: "https://x.dev/files",
            cookie: "session=1",
            userAgent: "Chrome",
            wasIntercepted: true
        )
        #expect(caught.headers["Cookie"] == "session=1")
        #expect(caught.headers["Referer"] == "https://x.dev/files")
        #expect(caught.headers["User-Agent"] == "Chrome")

        let bare = BridgeCatch(
            url: caught.url, fileName: nil, mimeType: nil, byteSize: nil,
            referrer: "", cookie: "", userAgent: nil, wasIntercepted: false
        )
        #expect(bare.headers.isEmpty)
    }
}

@MainActor
@Suite("Browser bridge routing")
struct BridgeRoutingTests {
    private func makeBridge(consent: Bool = true) -> BrowserBridge {
        let defaults = UserDefaults(suiteName: "bridge.tests") ?? .standard
        defaults.removePersistentDomain(forName: "bridge.tests")
        let storage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-\(UUID().uuidString).json")
        return BrowserBridge(
            preferences: Preferences(defaults: defaults),
            storageURL: storage,
            confirm: { _, _ in consent }
        )
    }

    private func request(
        _ method: String,
        _ path: String,
        origin: String? = nil,
        token: String? = nil,
        body: [String: Any] = [:]
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let origin { headers["origin"] = origin }
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        )
    }

    private func payload(_ response: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    /// The whole hand-off, in the order a browser performs it.
    @Test func pairingThenHandingOverADownloadWorks() async throws {
        let bridge = makeBridge()
        let origin = "chrome-extension://abc"

        var caught: [BridgeCatch] = []
        bridge.onCatch = { caught.append($0) }

        let paired = await bridge.handle(request("POST", "/pair", origin: origin, body: ["name": "Chrome"]))
        #expect(paired.status == 200)
        let token = try #require(payload(paired)["token"] as? String)
        #expect(bridge.clients.count == 1)

        let accepted = await bridge.handle(request(
            "POST", "/catch",
            origin: origin,
            token: token,
            body: [
                "url": "https://x.dev/a.zip",
                "filename": "/Users/me/Downloads/a.zip",
                "size": 4096,
                "cookie": "session=1",
                "referrer": "https://x.dev/files",
                "intercepted": true
            ]
        ))
        #expect(accepted.status == 202)
        #expect(caught.count == 1)
        #expect(caught.first?.fileName == "a.zip")
        #expect(caught.first?.byteSize == 4096)
        #expect(caught.first?.headers["Cookie"] == "session=1")
        #expect(caught.first?.wasIntercepted == true)
    }

    /// A refusal must leave nothing behind, and a page on the open web must not even be able to
    /// put the question on screen.
    @Test func aRefusedOrForgedPairingGrantsNothing() async {
        let refusing = makeBridge(consent: false)
        let refused = await refusing.handle(request("POST", "/pair", origin: "chrome-extension://abc"))
        #expect(refused.status == 403)
        #expect(refusing.clients.isEmpty)

        // No extension origin, no dialog, no token — whatever the consent closure would say.
        let bridge = makeBridge(consent: true)
        let forged = await bridge.handle(request("POST", "/pair", origin: "https://evil.example"))
        #expect(forged.status == 403)
        #expect(bridge.clients.isEmpty)

        let anonymous = await bridge.handle(request("POST", "/pair"))
        #expect(anonymous.status == 403)
    }

    /// Without a valid token nothing is accepted, and a revoked browser is out immediately.
    @Test func onlyAPairedBrowserCanHandOverADownload() async throws {
        let bridge = makeBridge()
        let origin = "chrome-extension://abc"
        var caught = 0
        bridge.onCatch = { _ in caught += 1 }

        let unauthorized = await bridge.handle(request(
            "POST", "/catch", origin: origin, body: ["url": "https://x.dev/a.zip"]
        ))
        #expect(unauthorized.status == 401)
        #expect(caught == 0)

        let paired = await bridge.handle(request("POST", "/pair", origin: origin))
        let token = try #require(payload(paired)["token"] as? String)

        let wrongToken = await bridge.handle(request(
            "POST", "/catch", origin: origin, token: "not-it", body: ["url": "https://x.dev/a.zip"]
        ))
        #expect(wrongToken.status == 401)

        bridge.revoke(try #require(bridge.clients.first))
        let revoked = await bridge.handle(request(
            "POST", "/catch", origin: origin, token: token, body: ["url": "https://x.dev/a.zip"]
        ))
        #expect(revoked.status == 401)
        #expect(caught == 0)
    }

    /// Only http and https are downloads. A `file:` url from a compromised extension would be
    /// asking this app to read the disk on its behalf.
    @Test func onlyWebUrlsAreAccepted() async throws {
        let bridge = makeBridge()
        let origin = "chrome-extension://abc"
        let paired = await bridge.handle(request("POST", "/pair", origin: origin))
        let token = try #require(payload(paired)["token"] as? String)

        for url in ["file:///etc/passwd", "ftp://x.dev/a.zip", "not a url at all", ""] {
            let response = await bridge.handle(request(
                "POST", "/catch", origin: origin, token: token, body: ["url": url]
            ))
            #expect(response.status == 400, "\(url) should be refused")
        }
    }

    /// Pairing again after a browser restart must not ask a second time.
    @Test func aKnownBrowserIsNotAskedAgain() async throws {
        let bridge = makeBridge()
        let origin = "chrome-extension://abc"
        let first = await bridge.handle(request("POST", "/pair", origin: origin))
        let second = await bridge.handle(request("POST", "/pair", origin: origin))

        #expect(payload(first)["token"] as? String == payload(second)["token"] as? String)
        #expect(bridge.clients.count == 1)
    }
}

@Suite("Sniffed media")
struct SniffedMediaTests {
    private func stream(
        _ itag: Int?,
        _ mime: String,
        size: Int64,
        label: String? = nil,
        playlist: Bool = false
    ) -> SniffedStream {
        SniffedStream(
            url: URL(string: "https://r1.googlevideo.com/videoplayback?itag=\(itag ?? 0)")!,
            mime: mime,
            itag: itag,
            byteSize: size,
            label: label,
            isPlaylist: playlist
        )
    }

    /// A YouTube format number is the only thing that says whether one file is the whole video.
    /// Getting this wrong means handing someone a silent film.
    @Test func aFormatNumberSaysWhetherAFileIsComplete() {
        #expect(stream(18, "video/mp4", size: 5_000_000).isComplete)
        #expect(stream(22, "video/mp4", size: 9_000_000).isComplete)
        #expect(stream(137, "video/mp4", size: 9_000_000).isVideoOnly)
        #expect(stream(248, "video/webm", size: 9_000_000).isVideoOnly)
        #expect(stream(140, "audio/mp4", size: 3_000_000).isAudioOnly)
        #expect(stream(251, "audio/webm", size: 3_000_000).isAudioOnly)

        // A plain file on a web server carries its own audio; nothing says otherwise.
        #expect(stream(nil, "video/mp4", size: 5_000_000).isComplete)
        #expect(stream(nil, "audio/mpeg", size: 3_000_000).isAudioOnly)
        // A playlist names its own tracks.
        #expect(stream(nil, "application/x-mpegurl", size: 0, playlist: true).isComplete)
    }

    /// Every video-only track is paired with the best audio, best picture first, and the audio
    /// on its own is offered last for someone who only wants the sound.
    @Test func videoTracksArePairedWithTheBestAudio() {
        let media = SniffedMedia(
            pageURL: URL(string: "https://www.youtube.com/watch?v=abc")!,
            title: "A song",
            streams: [
                stream(136, "video/mp4", size: 3_000_000, label: "720p"),
                stream(137, "video/mp4", size: 9_000_000, label: "1080p"),
                stream(140, "audio/mp4", size: 3_000_000, label: "128kbps"),
                stream(139, "audio/mp4", size: 1_000_000, label: "48kbps")
            ],
            headers: [:]
        )

        let options = media.options(hasFfmpeg: true)
        #expect(options.count == 3)
        #expect(options[0].label.hasPrefix("1080p"))
        #expect(options[0].needsMerge)
        // The best audio, not the first one seen.
        #expect(options[0].audioURL?.absoluteString.contains("itag=140") == true)
        #expect(options[0].byteSize == 12_000_000)
        #expect(options[0].fileExtension == "mp4")
        #expect(options[1].label.hasPrefix("720p"))
        #expect(options[2].audioURL == nil)
    }

    /// macOS joins the MP4 family on its own, so a pair in that family is offered whether or not
    /// anything is installed. This is what keeps a video download from requiring a command-line
    /// tool at all.
    @Test func mp4PairsNeedNothingInstalled() {
        let media = SniffedMedia(
            pageURL: URL(string: "https://www.youtube.com/watch?v=abc")!,
            title: "A song",
            streams: [
                stream(137, "video/mp4", size: 9_000_000, label: "1080p"),
                stream(140, "audio/mp4", size: 3_000_000, label: "128kbps")
            ],
            headers: [:]
        )

        let options = media.options(hasFfmpeg: false)
        #expect(options.contains { $0.label.hasPrefix("1080p") && $0.needsMerge })
        #expect(options.first { $0.needsMerge }?.fileExtension == "mp4")
    }

    /// WebM is outside what macOS writes, so a WebM pair is only offered where the external tool
    /// can take it — rather than offered and then failed at the last step.
    @Test func webmPairsWaitForTheExternalTool() {
        let media = SniffedMedia(
            pageURL: URL(string: "https://www.youtube.com/watch?v=abc")!,
            title: "A song",
            streams: [
                stream(248, "video/webm", size: 9_000_000, label: "1080p"),
                stream(251, "audio/webm", size: 3_000_000, label: "160kbps")
            ],
            headers: [:]
        )

        #expect(!media.options(hasFfmpeg: false).contains { $0.needsMerge })
        #expect(media.options(hasFfmpeg: true).contains { $0.needsMerge })
        // The sound on its own never needs joining.
        #expect(media.options(hasFfmpeg: false).contains { !$0.needsMerge })
    }

    /// A manifest is not a file: assembling one still needs the external tool, so offering it
    /// without that would be offering a download of a text playlist.
    @Test func playlistsAreOnlyOfferedWhenTheyCanBeAssembled() {
        let media = SniffedMedia(
            pageURL: URL(string: "https://lectures.example.edu/week-3")!,
            title: "Week 3",
            streams: [
                SniffedStream(
                    url: URL(string: "https://cdn.example/master.m3u8")!,
                    mime: "application/x-mpegurl", itag: nil, byteSize: nil,
                    label: nil, isPlaylist: true
                )
            ],
            headers: [:]
        )

        #expect(media.options(hasFfmpeg: false).isEmpty)
        let offered = media.options(hasFfmpeg: true)
        #expect(offered.count == 1)
        #expect(offered.first?.isPlaylist == true)
    }

    /// Mixing families cannot be copied into mp4 or webm, so it goes into a container that
    /// takes anything rather than failing at the last step.
    @Test func mixedCodecFamiliesGetAContainerThatTakesThem() {
        func container(video: String, audio: String) -> String? {
            SniffedMedia(
                pageURL: URL(string: "https://x.dev/a")!,
                title: "",
                streams: [
                    stream(137, video, size: 9_000_000, label: "1080p"),
                    stream(140, audio, size: 3_000_000)
                ],
                headers: [:]
            ).options(hasFfmpeg: true).first { $0.needsMerge }?.fileExtension
        }

        #expect(container(video: "video/mp4", audio: "audio/mp4") == "mp4")
        #expect(container(video: "video/webm", audio: "audio/webm") == "webm")
        #expect(container(video: "video/webm", audio: "audio/mp4") == "mkv")
    }

    /// The headers are what make a signed stream URL work outside the player, and `ffmpeg` takes
    /// them as one blob before the input they belong to.
    @Test func theMuxCarriesTheBrowserSHeaders() {
        let arguments = StreamMergeRunner.arguments(
            video: URL(string: "https://r1.googlevideo.com/videoplayback?itag=137")!,
            audio: URL(string: "https://r1.googlevideo.com/videoplayback?itag=140")!,
            destination: URL(fileURLWithPath: "/tmp/out.mp4"),
            headers: ["Cookie": "session=1", "Referer": "https://youtube.com", "User-Agent": "Chrome"]
        )

        let blob = arguments[arguments.firstIndex(of: "-headers")! + 1]
        #expect(blob.contains("Cookie: session=1"))
        #expect(blob.contains("Referer: https://youtube.com"))
        // The agent has its own flag, so it must not be repeated in the blob.
        #expect(!blob.contains("User-Agent"))
        #expect(arguments.contains("-user_agent"))

        // Two inputs, copied not re-encoded, and mapped so the picture comes from the first.
        #expect(arguments.filter { $0 == "-i" }.count == 2)
        #expect(arguments.contains("-c") && arguments.contains("copy"))
        #expect(arguments.contains("0:v:0") && arguments.contains("1:a:0"))
        #expect(arguments.last == "/tmp/out.mp4")

        // One input needs no mapping at all — a playlist carries both tracks.
        let single = StreamMergeRunner.arguments(
            video: URL(string: "https://x.dev/stream.m3u8")!,
            audio: nil,
            destination: URL(fileURLWithPath: "/tmp/out.mp4"),
            headers: [:]
        )
        #expect(single.filter { $0 == "-i" }.count == 1)
        #expect(!single.contains("-map"))
    }

    /// The extension's payload is untrusted, and a `file:` stream would be asking this app to
    /// read the disk on a page's behalf.
    @Test func onlyWebStreamsSurviveTheBridge() {
        #expect(BrowserBridge.stream(from: ["url": "https://x.dev/a.mp4", "mime": "video/mp4"]) != nil)
        #expect(BrowserBridge.stream(from: ["url": "file:///etc/passwd"]) == nil)
        #expect(BrowserBridge.stream(from: ["mime": "video/mp4"]) == nil)

        let parsed = BrowserBridge.stream(from: [
            "url": "https://x.dev/a.mp4", "mime": "video/mp4",
            "itag": 137, "size": 9_000_000, "label": "1080p"
        ])
        #expect(parsed?.itag == 137)
        #expect(parsed?.byteSize == 9_000_000)
        #expect(parsed?.height == 1080)
    }
}

@MainActor
@Suite("Island offers")
struct IslandOfferTests {
    private func makeModel() -> NotchModel {
        let defaults = UserDefaults(suiteName: "island.offers") ?? .standard
        defaults.removePersistentDomain(forName: "island.offers")
        let preferences = Preferences(defaults: defaults)
        let storage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offers-\(UUID().uuidString).json")
        return NotchModel(
            shelf: ShelfStore(),
            downloads: DownloadStore(preferences: preferences, storageURL: storage),
            calendar: CalendarService(),
            mixer: AudioMixerService(preferences: preferences),
            brightness: DisplayBrightnessService(),
            preferences: preferences
        )
    }

    private var offer: DownloadOffer {
        DownloadOffer(candidate: DownloadCandidate(
            url: URL(string: "https://x.dev/a.zip")!,
            fileName: "a.zip",
            kind: .archive,
            byteSize: 2048,
            isResumable: true,
            transport: .http,
            title: nil
        ))
    }

    /// A question arrives as a capsule, not a card: something unfolding over whatever someone is
    /// doing is an interruption for a download they may not want.
    @Test func anOfferArrivesAsACapsule() {
        let model = makeModel()
        model.presentOffer(offer)

        #expect(model.stage == .offer)
        #expect(model.isOffering)
        #expect(model.isOfferExpanded == false)
        #expect(model.offer?.title == "a.zip")
        // Two things cannot occupy the island at once.
        #expect(model.activity == nil)
    }

    /// Pointing at it is the ask. It grows, and the clock stops while it is being read.
    @Test func pointingAtTheCapsuleGrowsItIntoTheCard() {
        let model = makeModel()
        model.presentOffer(offer)

        model.setHovering(true)
        #expect(model.isOfferExpanded)
        #expect(model.stage == .offer)

        // And back to a capsule when the pointer leaves, rather than staying open.
        model.setHovering(false)
        #expect(model.isOfferExpanded == false)
        #expect(model.stage == .offer)
    }

    /// Whichever state it is in, answering it ends it — and a fresh offer starts small again.
    @Test func expansionDoesNotSurviveTheAnswer() {
        let model = makeModel()
        model.presentOffer(offer)
        model.setHovering(true)
        #expect(model.isOfferExpanded)

        model.acceptOffer()
        #expect(model.stage == .idle)
        #expect(model.isOfferExpanded == false)

        model.presentOffer(offer)
        #expect(model.isOfferExpanded == false)
    }

    /// Taking it up and turning it down both end the card, and each says so exactly once.
    @Test func answeringAnOfferEndsIt() {
        let model = makeModel()
        var accepted = 0, declined = 0, manual = 0
        model.onOpenDownloadPrompt = { accepted += 1 }
        model.onDeclineOffer = { declined += 1 }
        model.onEnterLinkManually = { manual += 1 }

        model.presentOffer(offer)
        model.acceptOffer()
        #expect(accepted == 1)
        #expect(model.stage == .idle)
        #expect(model.offer == nil)

        model.presentOffer(offer)
        model.declineOffer()
        #expect(declined == 1)
        #expect(model.stage == .idle)

        model.presentOffer(offer)
        model.enterLinkManually()
        #expect(manual == 1)
        #expect(model.stage == .idle)
    }

    /// Nothing may cut in front of an unanswered question — a track change least of all.
    @Test func anActivityWaitsForTheQuestionToBeAnswered() {
        let model = makeModel()
        model.presentOffer(offer)

        model.present(.volume(0.5))
        #expect(model.stage == .offer)
        #expect(model.activity == nil)
    }

    /// An offer arriving over the open panel would yank away the very thing the pointer is in,
    /// so it waits for the panel to close and then takes its turn.
    @Test func anOfferArrivingOverThePanelWaitsForIt() {
        let model = makeModel()
        model.setHovering(true)
        #expect(model.stage == .expanded)

        model.presentOffer(offer)
        #expect(model.stage == .expanded)

        model.setHovering(false)
        #expect(model.stage == .offer)
        #expect(model.offer?.title == "a.zip")
    }

    /// Hovering a card is reading it: the pointer must not swap it for the panel underneath.
    @Test func hoveringACardKeepsIt() {
        let model = makeModel()
        model.presentOffer(offer)

        model.setHovering(true)
        #expect(model.stage == .offer)

        model.setHovering(false)
        #expect(model.stage == .offer)
    }

    /// A card and the panel are different surfaces: pointing at an offer must never swap it for
    /// the panel underneath.
    @Test func anOfferIsNeverReplacedByThePanel() {
        let model = makeModel()
        model.presentOffer(offer)
        model.setHovering(true)
        #expect(model.stage == .offer)
        #expect(model.isExpanded == false)
    }

    /// While presenting, the island stays out of the way — a question over a slide is worse
    /// than a missed download.
    @Test func presentingModeSilencesOffers() {
        let model = makeModel()
        model.suppressesActivities = true
        model.presentOffer(offer)
        #expect(model.stage == .idle)
        #expect(model.offer == nil)
    }

    /// What the card says comes from the candidate: the best format when a page was sniffed, a
    /// plain size otherwise.
    @Test func theCardDescribesWhatWasFound() {
        #expect(offer.detail == Format.bytes(2048))
        #expect(offer.isMedia == false)
        #expect(offer.optionCount == 0)

        let sniffed = DownloadOffer(candidate: DownloadCandidate(
            url: URL(string: "https://www.youtube.com/watch?v=abc")!,
            fileName: "youtube.com",
            kind: .video,
            byteSize: 14_400_000,
            isResumable: false,
            transport: .http,
            title: "A song",
            streamOptions: [
                StreamOption(id: "1", label: "1080p · 9,9 MB", url: URL(string: "https://x.dev/v")!,
                             audioURL: URL(string: "https://x.dev/a")!, byteSize: 14_400_000,
                             fileExtension: "mp4"),
                StreamOption(id: "2", label: "720p · 3,3 MB", url: URL(string: "https://x.dev/v2")!,
                             audioURL: nil, byteSize: 3_300_000, fileExtension: "mp4")
            ]
        ))
        #expect(sniffed.title == "A song")
        #expect(sniffed.host == "youtube.com")
        #expect(sniffed.detail == "1080p · 9,9 MB")
        #expect(sniffed.isMedia)
        #expect(sniffed.optionCount == 2)
    }
}

@Suite("Pasted addresses")
struct PastedAddressTests {
    /// The bug this pins down: a pasted YouTube address is a page, and a page fetched as a file
    /// is a file full of HTML. Markup only counts as a download when the server says to save it
    /// or the address plainly names a file.
    @Test func aPageIsNotAFile() {
        let page = URL(string: "https://www.youtube.com/watch?v=abc")!
        #expect(!LinkProbe.isDownloadable(url: page, mimeType: "text/html", disposition: nil))
        #expect(!LinkProbe.isDownloadable(url: page, mimeType: "application/xhtml+xml", disposition: nil))

        // A server that insists is believed.
        #expect(LinkProbe.isDownloadable(
            url: page, mimeType: "text/html", disposition: "attachment; filename=\"page.html\""
        ))
        // And an address that names a file is one, whatever the type header says.
        #expect(LinkProbe.isDownloadable(
            url: URL(string: "https://x.dev/a.zip")!, mimeType: "text/html", disposition: nil
        ))
        // Anything that is not markup is a file.
        #expect(LinkProbe.isDownloadable(url: page, mimeType: "video/mp4", disposition: nil))
        #expect(LinkProbe.isDownloadable(url: page, mimeType: nil, disposition: nil))
    }

    /// A media page typed by hand has to reach the media path, which the host check is what
    /// decides. This is the check the manual prompt was missing.
    @Test func aTypedMediaPageIsRecognised() {
        for address in [
            "https://www.youtube.com/watch?v=NIVS1B6w77w",
            "https://youtu.be/NIVS1B6w77w",
            "https://www.youtube.com/shorts/abc"
        ] {
            let url = URL(string: address)!
            #expect(MediaTool.isMediaPage(url), "\(address) should be media")
            #expect(DownloadCoordinator.immediateCandidate(for: url)?.transport == .mediaTool)
        }
    }
}

@Suite("Stream labels")
struct StreamLabelTests {
    private func stream(_ mime: String, size: Int64? = nil, playlist: Bool = false) -> SniffedStream {
        SniffedStream(
            url: URL(string: "https://x.dev/stream")!,
            mime: mime,
            itag: nil,
            byteSize: size,
            label: nil,
            isPlaylist: playlist
        )
    }

    /// The bug behind a picker offering "MP3" four times: `application/x-mpegurl` contains
    /// "mpeg", and reading it as an MP3 mislabels every HLS stream on the web.
    @Test func aPlaylistIsNotAnMp3() {
        #expect(stream("application/x-mpegurl", playlist: true).fileExtension == "mp4")
        #expect(stream("application/vnd.apple.mpegurl", playlist: true).fileExtension == "mp4")
        #expect(stream("application/dash+xml", playlist: true).fileExtension == "mp4")
        // A real MP3 still is one.
        #expect(stream("audio/mpeg").fileExtension == "mp3")
        #expect(stream("video/mp4").fileExtension == "mp4")
        #expect(stream("audio/mp4").fileExtension == "m4a")
        #expect(stream("video/webm").fileExtension == "webm")
    }

    /// A row has to say what kind of track it is and what format, or a picker of four rows is
    /// four ways of choosing nothing.
    @Test func everyRowSaysSomethingAboutItself() {
        let audio = SniffedStream(
            url: URL(string: "https://x.dev/a")!, mime: "audio/mp4", itag: 140,
            byteSize: 3_000_000, label: nil, isPlaylist: false
        )
        let label = SniffedMedia.label(for: audio)
        #expect(label.contains("MP4"))
        #expect(label.contains(Format.bytes(3_000_000)))

        #expect(stream("application/x-mpegurl", playlist: true).formatName == "HLS")
        #expect(stream("video/x-matroska").formatName == "MATROSKA")
    }

    /// Where a site says nothing to tell its streams apart, the repeats are numbered rather than
    /// left identical.
    @Test func identicalRowsAreNumbered() {
        func option(_ id: String, _ label: String) -> StreamOption {
            StreamOption(
                id: id, label: label, url: URL(string: "https://x.dev/\(id)")!,
                audioURL: nil, byteSize: nil, fileExtension: "mp4"
            )
        }

        let labels = SniffedMedia.disambiguated([
            option("1", "Video · MP4"),
            option("2", "Video · MP4"),
            option("3", "1080p · 9,9 MB"),
            option("4", "Video · MP4")
        ]).map(\.label)

        #expect(labels == ["Video · MP4 (1)", "Video · MP4 (2)", "1080p · 9,9 MB", "Video · MP4 (3)"])
        #expect(Set(labels).count == labels.count)
    }
}

@MainActor
@Suite("Which path a page takes")
struct MediaRoutingTests {
    private func makeCoordinator() -> (DownloadCoordinator, Preferences, () -> [DownloadOffer]) {
        let defaults = UserDefaults(suiteName: "routing.tests") ?? .standard
        defaults.removePersistentDomain(forName: "routing.tests")
        let preferences = Preferences(defaults: defaults)
        let storage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("routing-\(UUID().uuidString).json")
        let coordinator = DownloadCoordinator(
            preferences: preferences,
            frontmostTracker: FrontmostApplicationTracker(),
            store: DownloadStore(preferences: preferences, storageURL: storage)
        )
        var offers: [DownloadOffer] = []
        coordinator.onOffer = { offers.append($0) }
        return (coordinator, preferences, { offers })
    }

    private func media(page: String, streams: [SniffedStream]) -> SniffedMedia {
        SniffedMedia(
            pageURL: URL(string: page)!,
            title: "A song",
            streams: streams,
            headers: ["Cookie": "session=1"]
        )
    }

    private var plainStream: SniffedStream {
        SniffedStream(
            url: URL(string: "https://cdn.example/video.mp4")!,
            mime: "video/mp4",
            itag: nil,
            byteSize: 20_000_000,
            label: nil,
            isPlaylist: false
        )
    }

    /// Watching requests only ever finds the one stream the player fetched. Where the helper
    /// knows the site, it lists every format — so the page goes to it rather than to a picker
    /// built from whatever happened to fly past.
    @Test func aKnownMediaPageGoesToTheHelper() {
        let (coordinator, preferences, offers) = makeCoordinator()
        // Point at something that exists and is executable, standing in for the helper.
        preferences.mediaToolPath = "/bin/echo"

        coordinator.offerMedia(media(
            page: "https://www.youtube.com/watch?v=abc",
            streams: [plainStream]
        ))

        #expect(offers().count == 1)
        #expect(offers().first?.isMedia == true)
        // No picker built from sniffed streams: the helper will offer the real formats.
        #expect(offers().first?.optionCount == 0)
        #expect(offers().first?.title == "A song")
    }

    /// With no helper installed, what the page was seen playing is all there is — and it is
    /// enough, which is the whole point of watching.
    @Test func withoutAHelperTheSniffedStreamsAreOffered() {
        let (coordinator, preferences, offers) = makeCoordinator()
        preferences.mediaToolPath = "/definitely/not/here"

        coordinator.offerMedia(media(
            page: "https://www.youtube.com/watch?v=abc",
            streams: [plainStream]
        ))

        #expect(offers().count == 1)
        #expect(offers().first?.optionCount == 1)
    }

    /// A site the helper never heard of is exactly where watching wins.
    @Test func anUnknownSiteAlwaysUsesWhatWasSeen() {
        let (coordinator, preferences, offers) = makeCoordinator()
        preferences.mediaToolPath = "/bin/echo"

        coordinator.offerMedia(media(
            page: "https://lectures.example.edu/week-3",
            streams: [plainStream]
        ))

        #expect(offers().first?.optionCount == 1)
    }

    /// A player reaching for the next segment must not ask again.
    @Test func aPageIsOnlyOfferedOnce() {
        let (coordinator, preferences, offers) = makeCoordinator()
        preferences.mediaToolPath = "/definitely/not/here"

        let found = media(page: "https://lectures.example.edu/week-3", streams: [plainStream])
        coordinator.offerMedia(found)
        coordinator.offerMedia(found)
        #expect(offers().count == 1)
    }
}

@Suite("Native muxing")
struct StreamMuxerTests {
    /// What AVFoundation will write. WebM is outside it, and the picker has to know that before
    /// offering a quality rather than after downloading two files for nothing.
    @Test func onlyContainersMacOSWritesAreAccepted() {
        for accepted in ["mp4", "MP4", "m4v", "mov", "m4a"] {
            #expect(StreamMuxer.canMux(fileExtension: accepted))
        }
        for refused in ["webm", "mkv", "weba", "ts", ""] {
            #expect(!StreamMuxer.canMux(fileExtension: refused))
        }
    }

    @Test func theContainerFollowsTheName() {
        #expect(StreamMuxer.fileType(for: URL(fileURLWithPath: "/tmp/a.mp4")) == .mp4)
        #expect(StreamMuxer.fileType(for: URL(fileURLWithPath: "/tmp/a.mov")) == .mov)
        #expect(StreamMuxer.fileType(for: URL(fileURLWithPath: "/tmp/a.m4a")) == .m4a)
        // Anything unexpected is written as MP4 rather than refused at the last step.
        #expect(StreamMuxer.fileType(for: URL(fileURLWithPath: "/tmp/a.bin")) == .mp4)
    }
}

@Suite("Joined downloads")
struct JoinedDownloadTests {
    private func item(phase: MergePhase?, transport: DownloadTransport = .streamMerge) -> DownloadItem {
        DownloadItem(
            url: URL(string: "https://x.dev/video")!,
            fileName: "clip.mp4",
            folder: URL(fileURLWithPath: "/tmp/dl"),
            kind: .video,
            transport: transport,
            secondaryURL: URL(string: "https://x.dev/audio")!,
            mergePhase: phase
        )
    }

    /// The halves are kept apart so each can resume on its own, and both carry an extension the
    /// shelf's folder watcher ignores.
    @Test func eachHalfHasItsOwnScratchFile() {
        let merging = item(phase: .video)
        #expect(merging.videoPartURL.lastPathComponent == "clip.mp4.video.part")
        #expect(merging.audioPartURL.lastPathComponent == "clip.mp4.audio.part")
        #expect(merging.videoPartURL.pathExtension == "part")
        #expect(merging.scratchURLs.count == 2)

        // An ordinary download keeps its single one.
        let plain = item(phase: nil, transport: .http)
        #expect(plain.scratchURLs == [plain.partURL])
    }

    /// Which half is in flight decides where the bytes go, and it survives a relaunch so a
    /// transfer paused during the second half does not start the first again.
    @Test func theCurrentHalfDecidesWhereBytesGo() throws {
        #expect(item(phase: .video).currentPartURL.lastPathComponent == "clip.mp4.video.part")
        #expect(item(phase: .audio).currentPartURL.lastPathComponent == "clip.mp4.audio.part")
        #expect(item(phase: nil).currentPartURL.lastPathComponent == "clip.mp4.video.part")

        var running = item(phase: .audio)
        running.completedPhaseBytes = 5_000
        let encoded = try JSONEncoder().encode(running)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: encoded)
        #expect(decoded.mergePhase == .audio)
        #expect(decoded.completedPhaseBytes == 5_000)
        #expect(decoded.secondaryURL == running.secondaryURL)
    }

    /// While the two files are being joined there is nothing to report in bytes, so the row says
    /// what is actually happening.
    @Test func joiningSaysSoRatherThanShowingASpeed() {
        var joining = item(phase: .joining)
        joining.state = .running
        joining.receivedBytes = 14_000_000
        #expect(joining.statusLine.localizedCaseInsensitiveContains("birleş")
            || joining.statusLine.localizedCaseInsensitiveContains("Joining"))
    }

    /// A picked stream decides how the queue fetches it: a manifest is assembled, a pair is
    /// joined, and a ready-made file is just a download.
    @Test func thePickedStreamDecidesTheTransport() {
        func option(playlist: Bool, audio: URL?) -> StreamOption {
            StreamOption(
                id: "1", label: "x", url: URL(string: "https://x.dev/v")!,
                audioURL: audio, byteSize: nil, fileExtension: "mp4", isPlaylist: playlist
            )
        }

        #expect(option(playlist: false, audio: nil).needsMerge == false)
        #expect(option(playlist: false, audio: URL(string: "https://x.dev/a")!).needsMerge)
        #expect(option(playlist: true, audio: nil).isPlaylist)
    }
}

@Suite("Assembler arguments")
struct StreamMergeArgumentTests {
    private func arguments(video: URL, audio: URL?) -> [String] {
        StreamMergeRunner.arguments(
            video: video,
            audio: audio,
            destination: URL(fileURLWithPath: "/tmp/out.mp4"),
            headers: ["Cookie": "session=1", "User-Agent": "Chrome"]
        )
    }

    /// Headers and reconnection are options of the HTTP protocol. Offered for a local file they
    /// are not merely useless — the whole command is refused over them, which is how a join of
    /// two already-downloaded halves failed with "Option not found".
    @Test func localFilesAreGivenNoHttpOptions() {
        let local = arguments(
            video: URL(fileURLWithPath: "/tmp/a.video.mp4"),
            audio: URL(fileURLWithPath: "/tmp/a.audio.m4a")
        )
        #expect(!local.contains("-headers"))
        #expect(!local.contains("-reconnect"))
        #expect(!local.contains("-user_agent"))
        // Paths, not file:// urls.
        #expect(local.contains("/tmp/a.video.mp4"))
        #expect(local.filter { $0 == "-i" }.count == 2)

        let remote = arguments(
            video: URL(string: "https://x.dev/v.mp4")!,
            audio: URL(string: "https://x.dev/a.m4a")!
        )
        #expect(remote.contains("-headers"))
        #expect(remote.contains("-reconnect"))
        #expect(remote.contains("https://x.dev/v.mp4"))
    }

    /// A manifest carries both tracks, so there is nothing to map.
    @Test func aManifestIsOneInputWithNoMapping() {
        let single = arguments(video: URL(string: "https://x.dev/master.m3u8")!, audio: nil)
        #expect(single.filter { $0 == "-i" }.count == 1)
        #expect(!single.contains("-map"))
        #expect(single.contains("-c") && single.contains("copy"))
    }
}

@Suite("What is playing")
struct NowPlayingSourceTests {
    private func process(_ bundleID: String?, playing: Bool) -> AudioProcessInfo {
        AudioProcessInfo(objectID: 1, pid: 42, bundleID: bundleID, isPlaying: playing)
    }

    /// Sound never comes out of a browser itself but out of a renderer it spawned, and those
    /// carry identifiers built on the browser's own. Missing them is why a playing video looked
    /// like silence.
    @Test func helperProcessesCountAsTheirBrowser() {
        #expect(WebBrowser.owning(bundleIdentifier: "com.google.Chrome") == .chrome)
        #expect(WebBrowser.owning(bundleIdentifier: "com.google.Chrome.helper") == .chrome)
        #expect(WebBrowser.owning(bundleIdentifier: "com.google.Chrome.helper.Renderer") == .chrome)
        #expect(WebBrowser.owning(bundleIdentifier: "com.brave.Browser.helper (Renderer)") == .brave)
        #expect(WebBrowser.owning(bundleIdentifier: "com.apple.Safari") == .safari)

        // Not a browser, and not something that merely starts alike.
        #expect(WebBrowser.owning(bundleIdentifier: "com.spotify.client") == nil)
        #expect(WebBrowser.owning(bundleIdentifier: "com.google.ChromeCanary") == nil)
        #expect(WebBrowser.owning(bundleIdentifier: nil) == nil)
        #expect(WebBrowser.owning(bundleIdentifier: "") == nil)
    }

    /// Only what is actually producing output counts — the measurement is the whole reason this
    /// answer can be trusted at all.
    @Test func onlyAudibleProcessesCount() {
        let browsers = BrowserTabReader.audibleBrowsers(in: [
            process("com.google.Chrome.helper.Renderer", playing: false),
            process("com.spotify.client", playing: true),
            process("com.apple.Safari", playing: true),
            process(nil, playing: true)
        ])
        #expect(browsers == [.safari])

        // One browser, however many of its processes are making noise.
        let deduped = BrowserTabReader.audibleBrowsers(in: [
            process("com.google.Chrome.helper.Renderer", playing: true),
            process("com.google.Chrome.helper", playing: true),
            process("com.google.Chrome", playing: true)
        ])
        #expect(deduped == [.chrome])
        #expect(BrowserTabReader.audibleBrowsers(in: []).isEmpty)
    }

    /// Browsers append their own name to every title, and it is the least useful part of a line
    /// with room for one thing.
    @Test func titlesLoseTheirBrowserSuffix() {
        #expect(MediaController.trimmedTitle("A song - YouTube", browser: .chrome) == "A song")
        #expect(MediaController.trimmedTitle("A page - Google Chrome", browser: .chrome) == "A page")
        #expect(MediaController.trimmedTitle("A page — Google Chrome", browser: .chrome) == "A page")
        // A title that simply mentions it keeps it.
        #expect(MediaController.trimmedTitle("YouTube tips and tricks", browser: .chrome)
            == "YouTube tips and tricks")
    }

    @Test func theSiteIsSaidThePlainWay() {
        #expect(MediaController.site(of: URL(string: "https://www.youtube.com/watch?v=a")!) == "youtube.com")
        #expect(MediaController.site(of: URL(string: "https://vimeo.com/123")!) == "vimeo.com")
    }

    /// The pane needs a name and an icon for what it is describing, and "System audio" is not
    /// what anyone would call the video they are watching.
    @Test func aBrowserSourceNamesItself() {
        let source = MediaSource.browser(.chrome)
        #expect(source.displayName == "Google Chrome")
        #expect(source.bundleIdentifier == "com.google.Chrome")
    }
}

@Suite("Page posters")
struct MediaPosterTests {
    /// A YouTube address carries its own identifier, so the still frame can be named without
    /// asking anyone anything.
    @Test func aYouTubeAddressNamesItsOwnThumbnail() {
        let expected = "NIVS1B6w77w"
        for address in [
            "https://www.youtube.com/watch?v=NIVS1B6w77w",
            "https://www.youtube.com/watch?v=NIVS1B6w77w&t=42",
            "https://youtu.be/NIVS1B6w77w",
            "https://www.youtube.com/shorts/NIVS1B6w77w",
            "https://www.youtube.com/live/NIVS1B6w77w",
            "https://www.youtube.com/embed/NIVS1B6w77w"
        ] {
            #expect(MediaPoster.youTubeIdentifier(in: URL(string: address)!) == expected, "\(address)")
        }

        // Not a video, and not an identifier.
        #expect(MediaPoster.youTubeIdentifier(in: URL(string: "https://www.youtube.com/")!) == nil)
        #expect(MediaPoster.youTubeIdentifier(in: URL(string: "https://www.youtube.com/watch?v=short")!) == nil)
        #expect(MediaPoster.youTubeIdentifier(in: URL(string: "https://vimeo.com/123456")!) == nil)
    }

    /// The largest thumbnail is not generated for every video, so the one that always exists
    /// follows it.
    @Test func theLargestThumbnailHasAFallback() {
        let urls = MediaPoster.youTubeThumbnails(for: "NIVS1B6w77w")
        #expect(urls.count == 2)
        #expect(urls[0].absoluteString.contains("maxresdefault"))
        #expect(urls[1].absoluteString.contains("hqdefault"))
        #expect(urls[0].host() == "i.ytimg.com")
    }

    /// `og:image` is the tag the whole web already fills in so links look right when shared, and
    /// sites write it every way round.
    @Test func theTagIsReadWhicheverWayItIsWritten() {
        let base = URL(string: "https://example.com/watch/1")!

        let plain = MediaPoster.posterURL(
            inMarkup: #"<meta property="og:image" content="https://cdn.example.com/a.jpg">"#,
            relativeTo: base
        )
        #expect(plain?.absoluteString == "https://cdn.example.com/a.jpg")

        // Reversed attribute order.
        let reversed = MediaPoster.posterURL(
            inMarkup: #"<meta content='https://cdn.example.com/b.jpg' property='og:image'/>"#,
            relativeTo: base
        )
        #expect(reversed?.absoluteString == "https://cdn.example.com/b.jpg")

        // Twitter's equivalent, for the sites that only write that one.
        let twitter = MediaPoster.posterURL(
            inMarkup: #"<meta name="twitter:image" content="/still.jpg">"#,
            relativeTo: base
        )
        #expect(twitter?.absoluteString == "https://example.com/still.jpg")

        // Protocol-relative, which plenty of sites still write.
        let relative = MediaPoster.posterURL(
            inMarkup: #"<meta property="og:image" content="//cdn.example.com/c.jpg">"#,
            relativeTo: base
        )
        #expect(relative?.absoluteString == "https://cdn.example.com/c.jpg")

        #expect(MediaPoster.posterURL(inMarkup: "<html><head></head></html>", relativeTo: base) == nil)
        // Not a picture anyone should be fetching.
        #expect(MediaPoster.posterURL(
            inMarkup: #"<meta property="og:image" content="javascript:alert(1)">"#,
            relativeTo: base
        ) == nil)
    }
}

@Suite("Cover art for pages")
struct BrowserArtworkTests {
    /// A page has no cover art but it does have a still frame, and that frame is what it would
    /// put on a link to itself. Carrying the page is what lets the pane ask for one.
    @Test func onlyABrowserSourceCarriesItsPage() {
        let page = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!
        let browser = NowPlaying(
            source: .browser(.chrome),
            title: "Me at the zoo",
            artist: "youtube.com",
            album: "",
            isPlaying: true,
            artworkURL: nil,
            position: nil,
            duration: nil,
            pageURL: page
        )
        #expect(browser.pageURL == page)
        #expect(browser.artworkURL == nil)
        // And the page yields something to show.
        #expect(MediaPoster.youTubeIdentifier(in: page) == "jNQXAC9IVRw")

        // A player hands its cover over directly, so nothing goes looking for a page.
        let player = NowPlaying(
            source: .app(.spotify),
            title: "A song",
            artist: "An artist",
            album: "An album",
            isPlaying: true,
            artworkURL: URL(string: "https://i.scdn.co/image/abc"),
            position: 10,
            duration: 200
        )
        #expect(player.pageURL == nil)
        #expect(player.artworkURL != nil)
    }
}

@MainActor
@Suite("Which tab is playing")
struct BrowserPlaybackTests {
    private func makeBridge() -> BrowserBridge {
        let defaults = UserDefaults(suiteName: "playing.tests") ?? .standard
        defaults.removePersistentDomain(forName: "playing.tests")
        let storage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("playing-\(UUID().uuidString).json")
        return BrowserBridge(
            preferences: Preferences(defaults: defaults),
            storageURL: storage,
            confirm: { _, _ in true }
        )
    }

    private func request(_ path: String, token: String?, body: [String: Any]) -> HTTPRequest {
        var headers = ["origin": "chrome-extension://abc"]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(
            method: "POST",
            path: path,
            headers: headers,
            body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        )
    }

    /// The browser is the only thing that knows which of its tabs is making sound, and reporting
    /// it is the whole fix for a video going quiet in the island the moment you switch tabs.
    @Test func theAudibleTabIsReportedWhicheverTabIsInFront() async throws {
        let bridge = makeBridge()
        var reports: [BrowserPlayback?] = []
        bridge.onPlaying = { reports.append($0) }

        let paired = await bridge.handle(request("/pair", token: nil, body: ["name": "Chrome"]))
        let payload = (try? JSONSerialization.jsonObject(with: paired.body)) as? [String: Any]
        let token = try #require(payload?["token"] as? String)

        let accepted = await bridge.handle(request("/playing", token: token, body: [
            "audible": true,
            "url": "https://www.youtube.com/watch?v=abc",
            "title": "A documentary - YouTube"
        ]))
        #expect(accepted.status == 202)
        #expect(reports.count == 1)
        #expect(reports.first??.title == "A documentary - YouTube")
        #expect(reports.first??.url.absoluteString == "https://www.youtube.com/watch?v=abc")

        // Nothing audible is as much of an answer as anything else.
        _ = await bridge.handle(request("/playing", token: token, body: ["audible": false]))
        #expect(reports.count == 2)
        #expect(reports.last! == nil)
    }

    /// Same gate as everything else: without a token nothing is heard.
    @Test func anUnpairedBrowserIsNotListenedTo() async {
        let bridge = makeBridge()
        var reports = 0
        bridge.onPlaying = { _ in reports += 1 }

        let response = await bridge.handle(request("/playing", token: nil, body: [
            "audible": true, "url": "https://x.dev/a", "title": "x"
        ]))
        #expect(response.status == 401)
        #expect(reports == 0)
    }

    /// A `file:` address from a compromised extension is not something to go describing, let
    /// alone fetching a poster for.
    @Test func onlyWebAddressesAreAccepted() async throws {
        let bridge = makeBridge()
        var reports: [BrowserPlayback?] = []
        bridge.onPlaying = { reports.append($0) }

        let paired = await bridge.handle(request("/pair", token: nil, body: [:]))
        let payload = (try? JSONSerialization.jsonObject(with: paired.body)) as? [String: Any]
        let token = try #require(payload?["token"] as? String)

        _ = await bridge.handle(request("/playing", token: token, body: [
            "audible": true, "url": "file:///etc/passwd", "title": "x"
        ]))
        // Treated as "nothing playing" rather than believed.
        #expect(reports.last! == nil)
    }
}

@Suite("Interruptions")
struct InterruptionTests {
    private func error(_ code: Int, domain: String = NSURLErrorDomain) -> NSError {
        NSError(domain: domain, code: code)
    }

    /// The difference between a download manager and a downloader: a dropped connection is not an
    /// answer, and a queue that treats it as one makes the user the retry mechanism.
    @Test func aDroppedConnectionIsNotAnAnswer() {
        for code in [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorSecureConnectionFailed
        ] {
            #expect(DownloadEngine.isTransient(error(code)), "\(code) should be worth retrying")
        }

        // A refusal is an answer. So is a cancellation, and anything that is not the network.
        for code in [NSURLErrorCancelled, NSURLErrorBadURL, NSURLErrorUnsupportedURL] {
            #expect(!DownloadEngine.isTransient(error(code)))
        }
        #expect(!DownloadEngine.isTransient(error(NSFileWriteOutOfSpaceError, domain: NSCocoaErrorDomain)))
    }

    /// Backing off keeps a queue from hammering a server that is down, and the last wait has to be
    /// long enough to cover a lift ride.
    @Test func theWaitsGrowAndAreBounded() {
        let delays = DownloadStore.retryDelays
        #expect(delays == delays.sorted())
        #expect(delays.first ?? 0 >= 1)
        #expect(delays.last ?? 0 >= 60)
        #expect(delays.count >= 3 && delays.count <= 8)
        // Long enough in total to ride out a real outage, short enough not to look abandoned.
        let total = delays.reduce(0, +)
        #expect(total > 60 && total < 600)
    }

    /// Waiting is a kind of running: the ring on the island should still turn, and the queue
    /// should not treat it as finished business.
    @Test func waitingCountsAsInFlight() {
        var item = DownloadItem(
            url: URL(string: "https://x.dev/a.zip")!,
            fileName: "a.zip",
            folder: URL(fileURLWithPath: "/tmp"),
            kind: .archive,
            totalBytes: 1000,
            receivedBytes: 400,
            state: .waiting
        )
        #expect(item.isActive)
        #expect(!item.state.isFinished)
        #expect(!item.state.isRunning)

        // And the row says what happened and when it will try again.
        item.failure = "Bağlantı koptu"
        item.retryAt = Date().addingTimeInterval(12)
        let line = item.statusLine
        #expect(line.contains("Bağlantı koptu"))
        #expect(line.contains("0:12") || line.contains("0:11"))

        // With the clock run out, it says it is going now rather than counting to zero.
        item.retryAt = Date().addingTimeInterval(-1)
        #expect(!item.statusLine.contains("0:00"))
    }
}

@MainActor
@Suite("Offer clock")
struct OfferClockTests {
    private func makeModel() -> NotchModel {
        let defaults = UserDefaults(suiteName: "offer.clock") ?? .standard
        defaults.removePersistentDomain(forName: "offer.clock")
        let preferences = Preferences(defaults: defaults)
        let storage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clock-\(UUID().uuidString).json")
        return NotchModel(
            shelf: ShelfStore(),
            downloads: DownloadStore(preferences: preferences, storageURL: storage),
            calendar: CalendarService(),
            mixer: AudioMixerService(preferences: preferences),
            brightness: DisplayBrightnessService(),
            preferences: preferences
        )
    }

    private var offer: DownloadOffer {
        DownloadOffer(candidate: DownloadCandidate(
            url: URL(string: "https://www.youtube.com/watch?v=abc")!,
            fileName: "youtube.com",
            kind: .video,
            byteSize: 2048,
            isResumable: false,
            transport: .mediaTool,
            title: "A video"
        ))
    }

    /// The bug this pins down: the island is told about every mouse move on the screen, and a
    /// pointer that is merely elsewhere is not an event. Restarting the clock on each of them left
    /// a question standing for as long as the mouse kept moving, which is most of the time.
    @Test func movingThePointerAroundDoesNotKeepTheOfferAlive() async {
        let model = makeModel()
        model.presentOffer(offer)

        // Twenty "the pointer is somewhere else" reports, as a moving mouse would produce.
        for _ in 0..<20 { model.setHovering(false) }

        #expect(model.stage == .offer)
        #expect(model.isOfferExpanded == false)

        // The clock it started with is still the one running, so it runs out.
        //
        // Waited for rather than slept through. A fixed sleep a few hundred milliseconds past the
        // deadline is a test that passes on an idle Mac and fails on a busy one — this one did,
        // twice in an afternoon — and a test that fails for being unlucky teaches nobody anything.
        // Polling still fails if the clock never runs out, which is the thing being checked.
        await untilTrue(within: .seconds(8)) { model.stage == .idle }
        #expect(model.stage == .idle)
        #expect(model.offer == nil)
    }

    /// Waits for a condition, or gives up. Returns as soon as it holds, so a passing test costs
    /// what it actually takes rather than a fixed pause.
    private func untilTrue(within limit: Duration, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Pointing at it still stops the clock, and taking the pointer away still starts it again.
    @Test func pointingAtItStillHoldsIt() async {
        let model = makeModel()
        model.presentOffer(offer)

        model.setHovering(true)
        #expect(model.isOfferExpanded)
        // Slept through rather than waited on: this one asserts that nothing happened, and there
        // is no condition to wait for when the expected outcome is "still there".
        try? await Task.sleep(for: .milliseconds(3400))
        #expect(model.stage == .offer, "a card being read should not have gone")

        model.setHovering(false)
        #expect(model.isOfferExpanded == false)
        await untilTrue(within: .seconds(8)) { model.stage == .idle }
        #expect(model.stage == .idle)
    }
}
