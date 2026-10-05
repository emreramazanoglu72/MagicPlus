//
//  NotchModel.swift
//  tabmenu
//

import AppKit
import CoreAudio
import Observation
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case media, mixer, agenda, shelf, downloads, mirror

    var id: String { rawValue }

    /// Tab labels sit in a narrow black pill, so translations need to stay short.
    var title: String {
        switch self {
        case .media: String(localized: "Now", comment: "Notch tab: what is playing right now")
        case .mixer: String(localized: "Mixer", comment: "Notch tab: per-app volume")
        case .agenda: String(localized: "Agenda", comment: "Notch tab: upcoming calendar events")
        case .shelf: String(localized: "Shelf", comment: "Notch tab: parked files")
        case .downloads: String(localized: "Get", comment: "Notch tab: the download queue")
        case .mirror: String(localized: "Mirror", comment: "Notch tab: camera preview")
        }
    }

    /// The module a pane belongs to, where it belongs to one. The rest are parts of the island
    /// itself and go wherever it does.
    var module: AppModule? {
        switch self {
        case .downloads: .downloads
        case .mixer, .media, .agenda, .shelf, .mirror: nil
        }
    }

    var symbolName: String {
        switch self {
        case .media: "waveform"
        case .mixer: "slider.horizontal.3"
        case .agenda: "calendar"
        case .shelf: "tray.full"
        case .downloads: "arrow.down.circle"
        case .mirror: "person.crop.square"
        }
    }
}

/// Drives the island.
///
/// The resting state is the hardware notch itself — nothing is drawn beyond it. Anything
/// worth saying arrives as a transient activity that expands the island briefly and then
/// collapses on its own; hovering opens the full panel.
@Observable
@MainActor
final class NotchModel {
    enum Stage: Equatable {
        /// Exactly the notch. Invisible.
        case idle
        /// A capsule flanking the notch, on its way out again.
        case activity
        /// A card hanging from the notch, waiting on an answer rather than reporting something.
        case offer
        /// Full panel, held open by the pointer.
        case expanded
    }

    private(set) var stage: Stage = .idle {
        didSet {
            guard stage != oldValue else { return }
            onStageChange?(stage)
        }
    }
    private(set) var activity: NotchActivity?
    /// The link the island is asking about.
    private(set) var offer: DownloadOffer?
    /// Whether that question is showing its full card or still just a capsule.
    ///
    /// It arrives as a capsule, because a card unfolding over whatever someone is doing is an
    /// interruption for something they may not want. Pointing at it is the ask, and that is when
    /// it grows.
    private(set) var isOfferExpanded = false
    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var battery = BatteryStatus(percentage: 100, isCharging: false, isPresent: false)
    private(set) var outputVolume: Double = 0.5
    private(set) var playbackOverride: Bool?
    private(set) var micLive = false
    private(set) var micMuted = false
    private(set) var cameraLive = false
    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var currentOutputDeviceID: AudioDeviceID?
    /// While presenting, transient activities stay quiet.
    var suppressesActivities = false

    var selectedTab: NotchTab = .media
    var isDropTargeted = false

    @ObservationIgnored let shelf: ShelfStore
    @ObservationIgnored let downloads: DownloadStore
    @ObservationIgnored let calendar: CalendarService
    @ObservationIgnored let mixer: AudioMixerService
    @ObservationIgnored let brightness: DisplayBrightnessService
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let volumeKeys = VolumeKeyMonitor()
    @ObservationIgnored private let screenshots = ScreenshotWatcher()
    @ObservationIgnored private let downloadWatcher = DownloadWatcher()

    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var hardwareTimer: Timer?
    @ObservationIgnored private var warnedLowBattery = false
    @ObservationIgnored private var warnedDiskFull = false
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var artworkURL: URL?
    /// The page whose still frame is standing in for cover art, so the same one is not fetched
    /// again on every poll.
    @ObservationIgnored private var artworkPageURL: URL?
    /// Which tab a browser extension says is making sound. Nothing outside the browser can know
    /// this, and without it a video playing in a tab nobody is looking at is described as
    /// whatever they moved on to.
    @ObservationIgnored private var reportedBrowserTab: BrowserPlayback?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// Track and event identities already announced, so a held state is not re-announced.
    @ObservationIgnored private var announcedTrack: String?
    @ObservationIgnored private var announcedEventID: String?
    /// Second, clickable announcement right before the meeting starts.
    @ObservationIgnored private var announcedJoinEventID: String?
    @ObservationIgnored private var wasCharging: Bool?
    @ObservationIgnored private var isAdjustingVolume = false

    private static let expandedInterval: TimeInterval = 1.5
    private static let restingInterval: TimeInterval = 6

    /// Handed a web link dropped on the island, which the download queue takes over.
    @ObservationIgnored var onDroppedLink: ((URL) -> Void)?
    /// The offer was taken up.
    @ObservationIgnored var onOpenDownloadPrompt: (() -> Void)?
    /// The guess was wrong: open the prompt with an empty address to type into.
    @ObservationIgnored var onEnterLinkManually: (() -> Void)?
    /// The offer was dismissed without being taken.
    @ObservationIgnored var onDeclineOffer: (() -> Void)?
    /// The window has to take mouse events while a card is up and give them back afterwards,
    /// which only the controller can do.
    @ObservationIgnored var onStageChange: ((Stage) -> Void)?
    /// An offer arriving while the panel is open waits for it to close rather than yanking it
    /// away mid-gesture.
    @ObservationIgnored private var deferredOffer: DownloadOffer?
    @ObservationIgnored private var offerTask: Task<Void, Never>?

    init(
        shelf: ShelfStore,
        downloads: DownloadStore,
        calendar: CalendarService,
        mixer: AudioMixerService,
        brightness: DisplayBrightnessService,
        preferences: Preferences
    ) {
        self.shelf = shelf
        self.downloads = downloads
        self.calendar = calendar
        self.mixer = mixer
        self.brightness = brightness
        self.preferences = preferences

        volumeKeys.onVolumeKey = { [weak self] in self?.handleVolumeKey() }
        screenshots.onNewScreenshot = { [weak self] url in self?.captureScreenshot(url) }
        downloadWatcher.onNewDownload = { [weak self] url in self?.announceDownload(url) }
    }

    /// Panes for modules that are switched on. A tab for something that is not running would be
    /// a tab with nothing behind it.
    var visibleTabs: [NotchTab] {
        NotchTab.allCases.filter { tab in
            guard let module = tab.module else { return true }
            return preferences.isEnabled(module)
        }
    }

    var isExpanded: Bool { stage == .expanded }
    var isOffering: Bool { stage == .offer }
    /// The idle island widens slightly to show these — they are safety signals, not noise.
    /// A muted mic with nothing recording is not chrome-worthy; muted matters exactly when
    /// something is trying to listen.
    var hasHardwareIndicator: Bool { micLive || cameraLive }

    /// A transfer in flight is worth a mark on the resting island: it is the one thing the
    /// user started deliberately and then walked away from.
    var isDownloading: Bool { downloads.hasActivity }

    /// Whether the resting island widens to carry any indicator at all.
    var hasIdleIndicator: Bool { hasHardwareIndicator || isDownloading }

    /// What the transport button shows.
    ///
    /// Spotify and Music report their own state. A browser tab cannot be queried, so the only
    /// record of whether it is playing is what the user last pressed — hence the override,
    /// which is also applied optimistically to queryable sources so the icon flips on the
    /// press rather than on the next poll. With no source at all, nothing is playing.
    var isPlaying: Bool {
        guard nowPlaying != nil else { return false }
        if let override = playbackOverride { return override }
        return nowPlaying?.isPlaying ?? true
    }

    private var sourceReportsPlaybackState: Bool { nowPlaying?.isPlaying != nil }

    // MARK: - Lifecycle

    func startUpdates() {
        ensureVisibleTab()
        restartTimer()
        calendar.start()
        volumeKeys.start()
        if preferences.capturesScreenshots { screenshots.start() }
        downloadWatcher.start()
        startHardwareTimer()
        refresh()
        refreshHardwareState()
    }

    func stopUpdates() {
        pollTimer?.invalidate()
        pollTimer = nil
        dismissTask?.cancel()
        calendar.stop()
        volumeKeys.stop()
        screenshots.stop()
        downloadWatcher.stop()
        hardwareTimer?.invalidate()
        hardwareTimer = nil
        stage = .idle
        activity = nil
    }

    private func restartTimer() {
        pollTimer?.invalidate()
        let interval = stage == .expanded ? Self.expandedInterval : Self.restingInterval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Stage

    func setHovering(_ hovering: Bool) {
        if hovering {
            dismissTask?.cancel()
            dismissTask = nil
            // A question the pointer is over is a question being read: it grows into its card,
            // and the clock stops rather than the panel underneath taking its place.
            if stage == .offer {
                offerTask?.cancel()
                offerTask = nil
                isOfferExpanded = true
                return
            }
            guard stage != .expanded else { return }
            ensureVisibleTab()
            stage = .expanded
            restartTimer()
            refresh()
        } else {
            if stage == .offer {
                // Only on the way out. This is told about every mouse move on the screen, and
                // restarting the clock each time meant a question nobody answered sat there for
                // as long as the pointer kept moving — which is most of the time.
                guard isOfferExpanded else { return }
                isOfferExpanded = false
                scheduleOfferDismissal()
                return
            }
            guard stage == .expanded else { return }
            stage = .idle
            activity = nil
            restartTimer()

            // Whatever turned up while the panel was open gets its turn now.
            if let deferred = deferredOffer {
                deferredOffer = nil
                presentOffer(deferred)
            }
        }
    }

    /// How long a question stands unanswered.
    ///
    /// Short, because a card nobody is looking at is in the way — and safe to keep short because
    /// pointing at one stops the clock, so it only ever runs out on an offer being ignored.
    private static let offerLifetime: Duration = .seconds(3)

    /// Grows the island into a card asking about a link.
    func presentOffer(_ offer: DownloadOffer) {
        guard !suppressesActivities else { return }
        // Never over the open panel: the pointer is already somewhere in it.
        guard stage != .expanded else {
            deferredOffer = offer
            return
        }

        dismissTask?.cancel()
        activity = nil
        self.offer = offer
        isOfferExpanded = false
        stage = .offer
        scheduleOfferDismissal()
    }

    private func scheduleOfferDismissal() {
        offerTask?.cancel()
        offerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.offerLifetime)
            guard !Task.isCancelled else { return }
            self?.declineOffer()
        }
    }

    func acceptOffer() {
        endOffer()
        onOpenDownloadPrompt?()
    }

    func enterLinkManually() {
        endOffer()
        onEnterLinkManually?()
    }

    func declineOffer() {
        endOffer()
        onDeclineOffer?()
    }

    private func endOffer() {
        offerTask?.cancel()
        offerTask = nil
        guard stage == .offer else { return }
        offer = nil
        isOfferExpanded = false
        stage = .idle
    }

    /// A pane remembered from before its module was switched off would open the panel on nothing.
    private func ensureVisibleTab() {
        let visible = visibleTabs
        guard !visible.contains(selectedTab), let first = visible.first else { return }
        selectedTab = first
    }

    /// Shows a transient activity, then collapses back to the bare notch on its own.
    func present(_ activity: NotchActivity) {
        // Presentation mode keeps the island silent; mic state is the exception because it
        // exists precisely for the meeting the user is presenting in.
        if suppressesActivities, activity.kindIdentifier != "micStatus" { return }
        // Never interrupt the open panel or an unanswered question, and never let a lesser
        // activity cut in front.
        guard stage != .expanded, stage != .offer else { return }
        if let current = self.activity,
           current.kindIdentifier != activity.kindIdentifier,
           current.priority > activity.priority {
            return
        }

        self.activity = activity
        stage = .activity
        scheduleDismissal(after: activity.duration)
    }

    private func scheduleDismissal(after duration: Duration) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    private func collapse() {
        dismissTask = nil
        guard stage == .activity else { return }
        stage = .idle
        activity = nil
    }

    /// Ends the current transient immediately — used after a capsule click has been served.
    func dismissActivity() {
        dismissTask?.cancel()
        collapse()
    }

    /// Click on the collapsed capsule: a joinable meeting joins outright; anything else
    /// opens the panel on the tab that explains the capsule.
    func handleActivityClick() -> Bool {
        guard stage == .activity, let activity else { return false }

        if case .meeting(let event) = activity, event.meetingURL != nil {
            calendar.join(event)
            dismissActivity()
            return true
        }

        switch activity {
        case .meeting: selectedTab = .agenda
        case .nowPlaying, .volume, .micStatus: selectedTab = .media
        case .screenshot, .filesAdded: selectedTab = .shelf
        case .download, .downloadStarted, .downloadFailed: selectedTab = .downloads
        default: break
        }
        return false
    }

    // MARK: - Sources

    /// Told by the browser extension which tab is audible, or that none is.
    func setBrowserPlayback(_ playback: BrowserPlayback?) {
        reportedBrowserTab = playback
        // Waiting up to six seconds to reflect a video that just started is a long time to look
        // at the wrong thing.
        refresh()
    }

    func refresh() {
        let wantsSystemReadings = stage == .expanded
        let skipVolume = isAdjustingVolume
        let reportedTab = reportedBrowserTab

        Task.detached(priority: .utility) {
            let media = MediaController.nowPlaying(reportedTab: reportedTab)
            let battery = SystemStatus.battery()
            let volume = skipVolume ? nil : SystemAudio.outputVolume()

            // Boot volume numbers, for the disk-almost-full warning.
            let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
            ])
            let total = (values?.volumeTotalCapacity).map(Int64.init)
            let free = values?.volumeAvailableCapacityForImportantUsage
            let ratio: Double? = (total ?? 0) > 0 ? 1 - Double(free ?? 0) / Double(total ?? 1) : nil

            await MainActor.run {
                self.apply(media)
                self.apply(battery)
                // Re-checked live: a drag may have started while the reading was in flight,
                // and a stale value would snap the slider back mid-gesture.
                if let volume, !self.isAdjustingVolume, self.outputVolume != volume {
                    self.outputVolume = volume
                }
                self.checkThresholds(diskFreeBytes: free, diskRatio: ratio)
                if wantsSystemReadings { self.refreshOutputDevices() }
            }
        }

        announceImminentMeetingIfNeeded()
    }

    private func apply(_ info: NowPlaying?) {
        // Only on a real change: this runs on a timer, and re-assigning an observable its own value
        // dirties the island's whole view graph for nothing.
        if nowPlaying != info { nowPlaying = info }

        if let info {
            let identity = "\(info.title)|\(info.artist)"
            // A browser's page is described, not announced. What it reports is the tab in front
            // rather than the one making the sound, so switching tabs during a video would
            // otherwise interrupt with a capsule naming the wrong thing.
            let isDescriptionOnly: Bool
            if case .browser = info.source { isDescriptionOnly = true } else { isDescriptionOnly = false }

            if identity != announcedTrack {
                announcedTrack = identity
                if !isDescriptionOnly { present(.nowPlaying(info)) }
            }
        } else {
            announcedTrack = nil
            // Nothing is playing, so a stale optimistic state must not linger.
            playbackOverride = nil
        }

        // Artwork and its source live and die together: a source without artwork must not keep
        // showing the previous one's cover, and clearing the key lets the same cover reload
        // when its source comes back.
        if let url = info?.artworkURL {
            artworkPageURL = nil
            guard url != artworkURL else { return }
            artworkURL = url
            artwork = nil
            loadArtwork(from: url)
            return
        }

        // A page has no cover art, but it has a still frame, and that is what it would put on a
        // link to itself.
        if let page = info?.pageURL {
            artworkURL = nil
            guard page != artworkPageURL else { return }
            artworkPageURL = page
            artwork = nil
            loadPoster(from: page)
            return
        }

        artwork = nil
        artworkURL = nil
        artworkPageURL = nil
        artworkTask?.cancel()
    }

    private func apply(_ status: BatteryStatus) {
        let previous = wasCharging
        if battery != status { battery = status }
        wasCharging = status.isCharging

        // Plugging in or unplugging is a moment worth surfacing; a steady state is not.
        if let previous, previous != status.isCharging, status.isPresent {
            present(.power(isCharging: status.isCharging, percentage: status.percentage))
        }
    }

    private func announceImminentMeetingIfNeeded() {
        guard let event = calendar.imminentEvent else {
            announcedEventID = nil
            announcedJoinEventID = nil
            return
        }

        // First heads-up when the event enters the 15-minute window.
        if event.id != announcedEventID {
            announcedEventID = event.id
            present(.meeting(event))
            return
        }

        // One more, one minute out — the capsule is clickable straight into the call.
        if event.meetingURL != nil,
           event.id != announcedJoinEventID,
           event.minutesUntilStart() <= 1 {
            announcedJoinEventID = event.id
            present(.meeting(event))
        }
    }

    private func loadArtwork(from url: URL) {
        artworkTask?.cancel()
        artworkTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data),
                  artworkURL == url
            else { return }
            artwork = image
        }
    }

    private func loadPoster(from page: URL) {
        artworkTask?.cancel()
        artworkTask = Task {
            let image = await MediaPoster.image(for: page)
            // The page may have moved on while this was in flight.
            guard let image, artworkPageURL == page else { return }
            artwork = image
        }
    }

    // MARK: - Hardware safety signals

    /// Mic and camera state polls on its own faster clock: a meeting indicator that lags six
    /// seconds behind reality is not an indicator.
    private func startHardwareTimer() {
        hardwareTimer?.invalidate()
        hardwareTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHardwareState() }
        }
    }

    func refreshHardwareState() {
        Task.detached(priority: .utility) {
            let candidates = SystemAudio.microphoneCaptureCandidates()
            let micMuted = SystemAudio.isInputMuted()
            let cameraLive = CameraActivity.isAnyCameraOn()

            await MainActor.run {
                self.micLive = candidates.contains { candidate in
                    Self.countsAsMicrophoneUser(
                        bundleID: candidate.bundleID,
                        isRegularApp: NSRunningApplication(processIdentifier: candidate.pid)?
                            .activationPolicy == .regular
                    )
                }
                self.micMuted = micMuted
                self.cameraLive = cameraLive
            }
        }
    }

    /// Which capture processes deserve the orange dot.
    ///
    /// Apple daemons listen around the clock — Siri's wake-word service above all — and the
    /// system's own indicator ignores them, so this does too: an Apple bundle only counts
    /// when it belongs to a real foreground application (FaceTime, QuickTime, Voice Memos).
    /// Everything else counts unconditionally, including browser helper processes.
    nonisolated static func countsAsMicrophoneUser(bundleID: String?, isRegularApp: Bool) -> Bool {
        guard let bundleID, bundleID.hasPrefix("com.apple.") else { return true }
        return isRegularApp
    }

    func refreshOutputDevices() {
        Task.detached(priority: .utility) {
            let devices = SystemAudio.outputDevices()
            let current = SystemAudio.defaultOutputDeviceID()
            await MainActor.run {
                self.outputDevices = devices
                self.currentOutputDeviceID = current
            }
        }
    }

    func selectOutputDevice(_ device: AudioOutputDevice) {
        currentOutputDeviceID = device.id
        Task.detached(priority: .userInitiated) {
            SystemAudio.setDefaultOutputDevice(device.id)
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run { self.refreshOutputDevices() }
        }
    }

    private func checkThresholds(diskFreeBytes: Int64?, diskRatio: Double?) {
        // Battery: warn once per discharge below 10%; re-arm when charged past 15% or plugged in.
        if battery.isPresent {
            if !battery.isCharging, battery.percentage <= 10 {
                if !warnedLowBattery {
                    warnedLowBattery = true
                    present(.lowBattery(battery.percentage))
                }
            } else if battery.isCharging || battery.percentage > 15 {
                warnedLowBattery = false
            }
        }

        // Disk: warn once past 95% used; re-arm when back under 90%.
        if let diskRatio, let diskFreeBytes {
            if diskRatio >= 0.95 {
                if !warnedDiskFull {
                    warnedDiskFull = true
                    present(.diskFull(freeBytes: diskFreeBytes))
                }
            } else if diskRatio < 0.9 {
                warnedDiskFull = false
            }
        }
    }

    // MARK: - Volume

    private func handleVolumeKey() {
        // The system applies the change slightly after the key event.
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard let level = SystemAudio.outputVolume() else { return }
            outputVolume = level
            present(.volume(level))
        }
    }

    func setVolume(_ ratio: Double) {
        outputVolume = ratio
        isAdjustingVolume = true
        Task.detached(priority: .userInitiated) {
            SystemAudio.setOutputVolume(ratio)
            try? await Task.sleep(for: .milliseconds(400))
            await MainActor.run { self.isAdjustingVolume = false }
        }
    }

    // MARK: - Playback

    private var controlSource: MediaSource { nowPlaying?.source ?? .system }

    func playPause() {
        playbackOverride = !isPlaying
        perform { MediaController.playPause($0) }
    }

    func nextTrack() {
        playbackOverride = true
        perform { MediaController.nextTrack($0) }
    }

    func previousTrack() {
        playbackOverride = true
        perform { MediaController.previousTrack($0) }
    }

    private func perform(_ command: @escaping @Sendable (MediaSource) -> Void) {
        let source = controlSource
        let clearsOverride = sourceReportsPlaybackState

        Task.detached(priority: .userInitiated) {
            command(source)
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                // Hand control back to sources that can speak for themselves.
                if clearsOverride { self.playbackOverride = nil }
                self.refresh()
            }
        }
    }

    // MARK: - Shelf

    func prepareForDrop() {
        selectedTab = .shelf
    }

    /// A fresh screenshot goes straight onto the shelf and announces itself, so it can be
    /// dragged somewhere useful without ever touching the Desktop.
    private func captureScreenshot(_ url: URL) {
        shelf.add([url])
        present(.screenshot(url))
    }

    /// Downloads are announced but not parked on the shelf: they already have a home, and
    /// silently collecting everything the user downloads would be presumptuous.
    private func announceDownload(_ url: URL) {
        present(.download(name: url.lastPathComponent))
    }

    /// Keeps the folder watcher quiet about a file this app is about to place itself, so one
    /// download never announces itself twice.
    func claimIncomingFile(_ name: String) {
        downloadWatcher.claim(name)
    }

    /// Files land on the shelf; web links are a download, which is the only thing that could
    /// sensibly be meant by dragging one onto the island.
    func acceptDrop(_ urls: [URL]) {
        let links = urls.filter { !$0.isFileURL }
        for link in links { onDroppedLink?(link) }
        if !links.isEmpty { selectedTab = .downloads }

        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else {
            isDropTargeted = false
            return
        }

        let before = shelf.files.count
        shelf.add(files)
        isDropTargeted = false
        selectedTab = .shelf

        let added = shelf.files.count - before
        if added > 0, stage != .expanded {
            present(.filesAdded(added))
        }
    }
}
