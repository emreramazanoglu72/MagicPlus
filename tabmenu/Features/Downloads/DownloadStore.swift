//
//  DownloadStore.swift
//  tabmenu
//

import AppKit
import Network
import Observation
import os

/// The download queue: what is waiting, what is moving, and what happened to the rest.
///
/// The list outlives the app. Anything that was running when MagicPlus quit comes back
/// paused with its byte count read off the partial file, so resuming continues the transfer
/// instead of starting it again.
@Observable
@MainActor
final class DownloadStore {
    private(set) var items: [DownloadItem] = []

    /// Set by the island so a finished or failed download can announce itself.
    @ObservationIgnored var onFinished: ((DownloadItem) -> Void)?
    @ObservationIgnored var onFailed: ((DownloadItem) -> Void)?
    /// Called with a file name just before it appears in the download folder, so the shelf's
    /// folder watcher does not announce the same arrival a second time.
    @ObservationIgnored var onWillPlaceFile: ((String) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Downloads")

    /// Assigned in `init` rather than declared lazily: a lazy property that captures `self`
    /// captures it as a mutable variable, which is a data race the compiler is right to flag.
    @ObservationIgnored private var engine: DownloadEngine!
    @ObservationIgnored private var media: MediaDownloadRunner!
    @ObservationIgnored private var merger: StreamMergeRunner!
    @ObservationIgnored private var hls: HLSDownloadRunner!
    @ObservationIgnored private var retryTasks: [UUID: Task<Void, Never>] = [:]
    /// What was running when the Mac went to sleep, so waking picks up exactly that.
    @ObservationIgnored private var pausedForSleep: [UUID] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    /// Finished entries kept in the list before the oldest are dropped.
    private static let historyLimit = 40

    /// - Parameter storageURL: Where the list is kept. Overridden by tests so they never
    ///   touch the real queue.
    init(preferences: Preferences, storageURL: URL? = nil) {
        self.preferences = preferences
        self.storageURL = storageURL
            ?? AppSupportDirectory.url().appendingPathComponent("downloads.json")
        load()

        // Every transport reports through the same door, and each hops to the main actor because
        // the queue is what they are reporting to.
        // `self` is bound before the hop in each: referencing the weak one from inside the
        // nested closure captures the same variable twice, which is a race the compiler is right
        // to object to.
        engine = DownloadEngine { [weak self] event in
            guard let store = self else { return }
            Task { @MainActor in store.apply(event) }
        }
        media = MediaDownloadRunner { [weak self] event in
            guard let store = self else { return }
            Task { @MainActor in store.apply(event) }
        }
        merger = StreamMergeRunner { [weak self] event in
            guard let store = self else { return }
            Task { @MainActor in store.apply(event) }
        }
        hls = HLSDownloadRunner { [weak self] event in
            guard let store = self else { return }
            Task { @MainActor in store.apply(event) }
        }

        observeInterruptions()
        discardOrphanedParts()
    }

    deinit {
        pathMonitor?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// The two things that stop a download without anything being wrong: the Mac sleeping and the
    /// network going away. Both come back, and so should the download.
    private func observeInterruptions() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            }
        ]

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // Bound before the hop: a weak `self` referenced from inside the nested closure is a
            // second capture of the same variable, which is what the compiler objects to.
            guard path.status == .satisfied, let store = self else { return }
            Task { @MainActor in store.retryAllWaiting() }
        }
        monitor.start(queue: DispatchQueue(label: "com.tabmenu.downloads.path"))
        pathMonitor = monitor
    }

    // MARK: - Queries

    var activeItems: [DownloadItem] { items.filter(\.isActive) }
    var runningCount: Int { items.filter { $0.state == .running }.count }
    var hasActivity: Bool { items.contains(where: \.isActive) }
    var totalSpeed: Double {
        items.filter { $0.state == .running }.reduce(0) { $0 + $1.bytesPerSecond }
    }

    /// One number for everything in flight, for the resting island's ring. `nil` while no
    /// running download knows its own size — a ring that guesses is worse than no ring.
    var overallProgress: Double? { Self.aggregateProgress(of: items) }

    /// Kept separate from the queue so the arithmetic can be checked on its own.
    nonisolated static func aggregateProgress(of items: [DownloadItem]) -> Double? {
        let sized = items.filter { $0.isActive && ($0.totalBytes ?? 0) > 0 }
        guard !sized.isEmpty else { return nil }
        let total = sized.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        let received = sized.reduce(Int64(0)) { $0 + $1.receivedBytes }
        guard total > 0 else { return nil }
        return min(max(Double(received) / Double(total), 0), 1)
    }

    func item(id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    /// Whether this link is already in the list, so nothing is offered or queued twice.
    func contains(_ url: URL) -> Bool {
        items.contains { $0.url == url && $0.state != .failed }
    }

    // MARK: - Destinations

    /// Where downloads go by default: the folder the user chose, falling back to ~/Downloads.
    var downloadFolder: URL {
        let configured = preferences.downloadFolderPath.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The folder a given kind lands in, which is the download folder itself unless sorting
    /// is switched on.
    func folder(for kind: DownloadKind) -> URL {
        guard preferences.sortsDownloadsByKind else { return downloadFolder }
        return downloadFolder.appendingPathComponent(kind.folderName, isDirectory: true)
    }

    // MARK: - Adding

    /// Puts a link in the queue. Returns the item so the caller can show it straight away.
    @discardableResult
    func add(
        _ candidate: DownloadCandidate,
        fileName: String? = nil,
        folder: URL? = nil,
        quality: MediaQuality? = nil,
        headers: [String: String]? = nil,
        secondaryURL: URL? = nil,
        /// `false` parks the entry in the queue without opening a connection.
        startsImmediately: Bool = true
    ) -> DownloadItem {
        let destination = folder ?? self.folder(for: candidate.kind)
        let item = DownloadItem(
            url: candidate.url,
            fileName: LinkProbe.sanitize(fileName ?? candidate.fileName),
            folder: destination,
            kind: candidate.kind,
            transport: candidate.transport,
            totalBytes: candidate.byteSize,
            state: startsImmediately ? .queued : .paused,
            isResumable: candidate.isResumable,
            mediaQuality: quality?.rawValue,
            headers: (headers?.isEmpty ?? true) ? nil : headers,
            secondaryURL: secondaryURL
        )

        items.insert(item, at: 0)
        trimHistory()
        persist()
        pump()
        return item
    }

    // MARK: - Control

    func start(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state != .running, items[index].state != .completed else { return }
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        items[index].state = .queued
        items[index].failure = nil
        items[index].retryAt = nil
        // Asked for by hand, so it gets the full run of attempts again.
        items[index].attempt = 0
        persist()
        pump()
    }

    func pause(_ id: UUID) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isActive else { return }
        let item = items[index]
        items[index].state = .paused
        items[index].bytesPerSecond = 0
        items[index].retryAt = nil
        persist()

        stop(item)
        pump()
    }

    func toggle(_ id: UUID) {
        guard let item = item(id: id) else { return }
        switch item.state {
        case .running, .queued: pause(id)
        // Waiting is not idle: pressing it means "stop waiting and go now".
        case .paused, .failed, .waiting: start(id)
        case .completed: open(item)
        }
    }

    /// Takes an entry out of the list. The partial file goes with it; a finished file stays
    /// where it is, because removing a download from a list must never delete the user's file.
    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        if item.isActive { stop(item) }
        if item.state != .completed {
            for scratch in item.scratchURLs { try? FileManager.default.removeItem(at: scratch) }
        }
        items.remove(at: index)
        persist()
        pump()
    }

    private func stop(_ item: DownloadItem) {
        switch item.transport {
        // Both halves of a joined download come through the byte engine, one after the other.
        case .http, .streamMerge: engine.pause(id: item.id)
        case .mediaTool: media.pause(id: item.id)
        case .playlist: hls.pause(id: item.id)
        }
    }

    func pauseAll() {
        for item in items where item.isActive { pause(item.id) }
    }

    func resumeAll() {
        for item in items where item.state == .paused || item.state == .failed { start(item.id) }
    }

    func clearFinished() {
        items.removeAll(where: \.state.isFinished)
        persist()
    }

    // MARK: - Finder

    func open(_ item: DownloadItem) {
        guard item.state == .completed else { return }
        NSWorkspace.shared.open(item.destinationURL)
    }

    func revealInFinder(_ item: DownloadItem) {
        let target = item.state == .completed ? item.destinationURL : item.currentPartURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            NSWorkspace.shared.open(item.folder)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func copyLink(_ item: DownloadItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
    }

    // MARK: - Queue

    /// Starts whatever is waiting, up to the limit the user set. Called after every state
    /// change, so the queue is always as busy as it is allowed to be.
    private func pump() {
        let limit = max(1, preferences.maximumConcurrentDownloads)
        guard runningCount < limit else { return }

        for index in items.indices where items[index].state == .queued {
            guard runningCount < limit else { break }
            launch(at: index)
        }
    }

    private func launch(at index: Int) {
        let item = items[index]

        // Better to say so now than to fail on the last byte. Only checked when the size is
        // known, and with room to spare, because a disk filled to the rim breaks other things.
        if let needed = item.totalBytes, let free = availableBytes(at: item.folder),
           free < needed - item.receivedBytes + Self.diskMargin {
            items[index].state = .failed
            items[index].failure = String(
                localized: "Not enough room — \(Format.bytes(needed)) needed",
                comment: "Download failure when the disk is too full"
            )
            persist()
            return
        }

        guard ensureFolder(item.folder) else {
            items[index].state = .failed
            items[index].failure = String(
                localized: "Cannot create the download folder",
                comment: "Download failure"
            )
            persist()
            return
        }

        switch item.transport {
        case .http:
            let offset = fileSize(at: item.partURL)
            items[index].receivedBytes = offset
            items[index].state = .running
            engine.start(
                id: item.id,
                url: item.url,
                partURL: item.partURL,
                offset: offset,
                headers: item.headers
            )

        case .streamMerge:
            // Each half is an ordinary download, which is what earns them resume, exact progress
            // and the browser's own headers. Joining happens once both are on disk.
            var phase = item.mergePhase ?? .video
            let manager = FileManager.default
            if phase == .joining,
               !(manager.fileExists(atPath: item.videoPartURL.path)
                 && manager.fileExists(atPath: item.audioPartURL.path)) {
                // The halves are gone, so there is nothing to join; start over.
                phase = .video
                items[index].completedPhaseBytes = 0
            }

            items[index].mergePhase = phase
            items[index].state = .running
            items[index].isResumable = true

            if phase == .joining {
                persist()
                join(item.id)
                return
            }

            let source = phase == .audio ? (item.secondaryURL ?? item.url) : item.url
            let partURL = phase == .audio ? item.audioPartURL : item.videoPartURL
            let offset = fileSize(at: partURL)
            items[index].receivedBytes = items[index].completedPhaseBytes + offset
            engine.start(
                id: item.id,
                url: source,
                partURL: partURL,
                offset: offset,
                headers: item.headers
            )

        case .playlist:
            // Assembled by the app itself: the segments are fetched, appended in order and then
            // rewritten into an MP4 with what macOS already has. This used to hand the whole job
            // to `ffmpeg`, which put an install step in front of the sites people most often
            // want something from.
            //
            // The name is settled before a byte is written, the same way every other download
            // settles it, because the assembler produces the finished file directly.
            let destination = Self.finalMove(for: item).to
            items[index].fileName = destination.lastPathComponent
            items[index].state = .running
            items[index].isResumable = true
            onWillPlaceFile?(destination.lastPathComponent)
            hls.start(
                id: item.id,
                url: item.url,
                destination: destination,
                scratch: item.partURL,
                preferredHeight: MediaQuality(rawValue: item.mediaQuality ?? "")?.maximumHeight,
                headers: item.headers ?? [:]
            )

        case .mediaTool:
            guard let tool = MediaTool.resolve(configuredPath: preferences.mediaToolPath) else {
                items[index].state = .failed
                items[index].failure = String(
                    localized: "The media helper is not installed",
                    comment: "Download failure"
                )
                persist()
                return
            }
            items[index].state = .running
            media.start(
                id: item.id,
                url: item.url,
                quality: MediaQuality(rawValue: item.mediaQuality ?? "") ?? .best,
                folder: item.folder,
                tool: tool,
                cookies: preferences.mediaCookieSource
            )
        }
        persist()
    }

    // MARK: - Events

    private func apply(_ event: DownloadEvent) {
        switch event {
        case .started(let id, let totalBytes, let receivedBytes, let isResumable):
            update(id) { item in
                item.state = .running
                if item.transport == .streamMerge {
                    // The engine only knows the half in flight; the item's total covers both, so
                    // neither number from here may overwrite it.
                    item.receivedBytes = item.completedPhaseBytes + receivedBytes
                } else {
                    item.receivedBytes = receivedBytes
                    item.isResumable = isResumable
                    if let totalBytes { item.totalBytes = totalBytes }
                }
            }
            persist()

        case .progress(let id, let receivedBytes, let bytesPerSecond):
            update(id) { item in
                let total = item.transport == .streamMerge
                    ? item.completedPhaseBytes + receivedBytes
                    : receivedBytes
                // Absolute values, so a message that overtook another can only be stale.
                guard total >= item.receivedBytes else { return }
                item.receivedBytes = total
                item.bytesPerSecond = bytesPerSecond
            }

        case .resized(let id, let totalBytes):
            update(id) { $0.totalBytes = totalBytes }

        case .named(let id, let fileName):
            update(id) { $0.fileName = LinkProbe.sanitize(fileName) }
            persist()

        case .finished(let id, let receivedBytes):
            if let item = item(id: id), item.transport == .streamMerge, item.mergePhase != .joining {
                advanceMerge(id, receivedBytes: receivedBytes)
            } else {
                complete(id, receivedBytes: receivedBytes)
            }

        case .failed(let id, let reason, let isTransient):
            // A dropped connection is not an answer. The queue picks it up again rather than
            // making the user the retry mechanism.
            if isTransient, let attempt = scheduleRetry(id, reason: reason) {
                logger.notice("retrying attempt \(attempt, privacy: .public) after an interruption")
                return
            }

            update(id) { item in
                item.state = .failed
                item.failure = reason
                item.bytesPerSecond = 0
                item.retryAt = nil
            }
            persist()
            if let item = item(id: id) { onFailed?(item) }
            pump()
        }
    }

    // MARK: - Interruptions

    /// How long to wait before each attempt. Backing off keeps a queue from hammering a server
    /// that is down, and the last one is far enough out to cover a lift ride.
    static let retryDelays: [TimeInterval] = [2, 6, 15, 40, 90]

    /// Puts a download back in line after an interruption.
    ///
    /// - Returns: which attempt this is, or `nil` when there are none left and it is a real
    ///   failure after all.
    private func scheduleRetry(_ id: UUID, reason: String) -> Int? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let attempt = items[index].attempt
        guard attempt < Self.retryDelays.count else { return nil }

        let delay = Self.retryDelays[attempt]
        items[index].attempt = attempt + 1
        items[index].state = .waiting
        items[index].failure = reason
        items[index].bytesPerSecond = 0
        items[index].retryAt = Date().addingTimeInterval(delay)
        persist()
        // Something else can use the slot while this one waits.
        pump()

        retryTasks[id]?.cancel()
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryNow(id)
        }
        return attempt + 1
    }

    /// Starts a waiting download, whether its clock ran out or something else woke it.
    private func retryNow(_ id: UUID) {
        retryTasks[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .waiting
        else { return }
        items[index].state = .queued
        items[index].retryAt = nil
        pump()
    }

    /// Everything waiting goes now.
    ///
    /// Called when the network comes back or the Mac wakes: the reason a download stopped has
    /// just gone away, so there is no sense in sitting out the rest of a backoff.
    func retryAllWaiting() {
        for item in items where item.state == .waiting { retryNow(item.id) }
    }

    /// Sleep is not a failure. Anything in flight is put down deliberately so it comes back as a
    /// download to resume rather than a connection that died.
    private func handleSleep() {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return }
        pausedForSleep = running.map(\.id)
        for item in running {
            stop(item)
            update(item.id) { $0.state = .waiting; $0.retryAt = nil; $0.bytesPerSecond = 0 }
        }
        persist()
    }

    private func handleWake() {
        let sleeping = pausedForSleep
        pausedForSleep = []
        for id in sleeping { retryNow(id) }
        retryAllWaiting()
    }

    // MARK: - Joining

    /// One half of a joined download finished; move on to the other, or to the join.
    private func advanceMerge(_ id: UUID, receivedBytes: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        item.completedPhaseBytes += receivedBytes
        item.receivedBytes = item.completedPhaseBytes
        item.bytesPerSecond = 0

        guard item.mergePhase == .video, let audio = item.secondaryURL else {
            item.mergePhase = .joining
            items[index] = item
            persist()
            join(id)
            return
        }

        item.mergePhase = .audio
        items[index] = item
        persist()

        let partURL = item.audioPartURL
        engine.start(
            id: id,
            url: audio,
            partURL: partURL,
            offset: fileSize(at: partURL),
            headers: item.headers
        )
    }

    /// Both halves are on disk. Joins them with what macOS already has, and falls back to the
    /// external tool for the files it reads better — nothing is downloaded twice either way.
    private func join(_ id: UUID) {
        guard let joining = item(id: id) else { return }

        let destination = Self.finalMove(for: joining).to
        update(id) { $0.fileName = destination.lastPathComponent }
        onWillPlaceFile?(destination.lastPathComponent)

        let video = joining.videoPartURL
        let audio = joining.audioPartURL
        let audioExtension = StreamMuxer.canMux(fileExtension: destination.pathExtension) ? "m4a" : "webm"

        Task { [weak self] in
            let failure = await Self.joinFiles(
                video: video,
                audio: audio,
                into: destination,
                videoExtension: destination.pathExtension,
                audioExtension: audioExtension
            )
            guard let self else { return }

            guard failure == nil else {
                update(id) { item in
                    item.state = .failed
                    item.failure = failure
                    item.mergePhase = nil
                    item.bytesPerSecond = 0
                }
                persist()
                if let failed = item(id: id) { onFailed?(failed) }
                pump()
                return
            }

            for scratch in [video, audio] { try? FileManager.default.removeItem(at: scratch) }
            update(id) { $0.mergePhase = nil }
            complete(id, receivedBytes: fileSize(at: destination))
        }
    }

    /// - Returns: `nil` on success, or why it could not be done.
    ///
    /// The halves are linked to names carrying their real extensions first. AVFoundation chooses
    /// a parser from the extension, and a file called `.part` tells it nothing — a hard link
    /// costs no space and leaves the originals in place for a retry.
    private static func joinFiles(
        video: URL,
        audio: URL,
        into destination: URL,
        videoExtension: String,
        audioExtension: String
    ) async -> String? {
        let videoTyped = typedLink(for: video, extension: videoExtension)
        let audioTyped = typedLink(for: audio, extension: audioExtension)
        defer {
            for link in [videoTyped, audioTyped] where link != video && link != audio {
                try? FileManager.default.removeItem(at: link)
            }
        }

        do {
            try await StreamMuxer.mux(video: videoTyped, audio: audioTyped, into: destination)
            return nil
        } catch {
            // macOS misreads the timing in some sites' per-track files and refuses rather than
            // write a video at half speed. The external tool reads those correctly, so it gets
            // the same two local files rather than a second download.
            if let tool = MediaTool.merger() {
                do {
                    try await StreamMergeRunner.mux(
                        video: videoTyped,
                        audio: audioTyped,
                        into: destination,
                        tool: tool
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            return (error as? StreamMuxer.Failure)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A hard link to the same bytes under a name that says what they are. Dot-prefixed, so it
    /// is neither visible in Finder nor picked up by the shelf's folder watcher.
    private static func typedLink(for url: URL, extension fileExtension: String) -> URL {
        let manager = FileManager.default
        let link = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).\(fileExtension)")

        try? manager.removeItem(at: link)
        do {
            try manager.linkItem(at: url, to: link)
            return link
        } catch {
            // A different volume, or a filesystem without links: a copy still works, it just
            // costs the space for as long as the join takes.
            guard (try? manager.copyItem(at: url, to: link)) != nil else { return url }
            return link
        }
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// Turns the partial file into the finished one.
    ///
    /// The helper writes its own file and needs no rename; an HTTP transfer moves its `.part`
    /// into place, taking a numbered name if something is already there — overwriting a file
    /// the user already has is not a download manager's decision to make.
    private func complete(_ id: UUID, receivedBytes: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        item.bytesPerSecond = 0
        item.receivedBytes = receivedBytes
        if item.totalBytes == nil { item.totalBytes = receivedBytes }

        if item.transport == .http {
            let move = Self.finalMove(for: item)
            item.fileName = move.to.lastPathComponent
            onWillPlaceFile?(item.fileName)
            do {
                try FileManager.default.moveItem(at: move.from, to: move.to)
            } catch {
                item.state = .failed
                item.failure = error.localizedDescription
                items[index] = item
                persist()
                onFailed?(item)
                pump()
                return
            }
        } else {
            onWillPlaceFile?(item.fileName)
        }

        item.state = .completed
        item.failure = nil
        items[index] = item
        trimHistory()
        persist()
        onFinished?(item)
        pump()
    }

    /// The move that finishes an HTTP transfer.
    ///
    /// Both halves have to be worked out together. The source is derived from the name the
    /// transfer has been writing under, and the destination may have to take a numbered name
    /// because overwriting a file the user already has is not a download manager's decision —
    /// so reading the source after renaming would look for a partial file that never existed.
    nonisolated static func finalMove(
        for item: DownloadItem,
        using manager: FileManager = .default
    ) -> (from: URL, to: URL) {
        let source = item.partURL
        let base = (item.fileName as NSString).deletingPathExtension
        let `extension` = (item.fileName as NSString).pathExtension
        var destination = item.destinationURL
        var suffix = 2

        while manager.fileExists(atPath: destination.path) {
            let name = `extension`.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(`extension`)"
            destination = item.folder.appendingPathComponent(name)
            suffix += 1
            // A folder holding a thousand files of the same name is a bug somewhere else;
            // stop rather than loop forever.
            if suffix > 999 { break }
        }
        return (source, destination)
    }

    // MARK: - Files

    private func ensureFolder(_ url: URL) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { return true }
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            logger.error("cannot create \(url.path, privacy: .public)")
            return false
        }
    }

    /// Headroom left on the volume beyond what a download needs. A disk with nothing left is a
    /// Mac with problems bigger than one download.
    private static let diskMargin: Int64 = 256 * 1024 * 1024

    private func availableBytes(at folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    // MARK: - Persistence

    private func trimHistory() {
        let finished = items.filter(\.state.isFinished)
        guard finished.count > Self.historyLimit else { return }
        let doomed = Set(finished.suffix(finished.count - Self.historyLimit).map(\.id))
        items.removeAll { doomed.contains($0.id) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let stored = try? JSONDecoder().decode([DownloadItem].self, from: data)
        else { return }

        items = stored.map { item in
            var restored = item
            // Nothing is running after a relaunch. What was in flight comes back paused,
            // with the byte count read off the partial file rather than trusted from disk.
            if restored.state == .running || restored.state == .queued || restored.state == .waiting {
                restored.state = .paused
            }
            restored.attempt = 0
            restored.retryAt = nil
            if restored.state != .completed, restored.transport == .http {
                restored.receivedBytes = fileSize(at: restored.partURL)
            }
            return restored
        }
    }

    /// Sweeps up partial files nothing is coming back for.
    ///
    /// A download removed while the app was not running, or one whose entry was cleared, leaves
    /// its `.part` behind — and the download folder is the user's, not a scratch space. Only ours
    /// are touched, only ones no entry claims, and only after a week, because "no entry claims it"
    /// is also true of a download the user paused and means to resume next month.
    private func discardOrphanedParts() {
        let manager = FileManager.default
        let claimed = Set(items.flatMap(\.scratchURLs).map(\.standardizedFileURL))
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        var folders = Set(items.map(\.folder.standardizedFileURL))
        folders.insert(downloadFolder.standardizedFileURL)

        for folder in folders {
            guard let contents = try? manager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants]
            ) else { continue }

            for url in contents where url.pathExtension == "part" {
                guard !claimed.contains(url.standardizedFileURL) else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modified, modified < cutoff else { continue }
                try? manager.removeItem(at: url)
                logger.notice("removed an abandoned partial file")
            }
        }
    }

    private func persist() {
        do {
            try JSONEncoder().encode(items).write(to: storageURL, options: .atomic)
            // The queue can hold cookies handed over by the browser, so it is a credential
            // file: this user and nobody else.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageURL.path
            )
        } catch {
            logger.error("failed to save downloads: \(error.localizedDescription, privacy: .public)")
        }
    }
}
