//
//  DownloadPrompt.swift
//  tabmenu
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Asks before downloading anything.
///
/// The whole feature turns on this panel existing. A link grabber that starts writing files
/// the moment something lands on the clipboard is a liability — the interesting question is
/// never "did you copy a link" but "where should this go, and which version of it" — so the
/// detection is ambient and the decision is always explicit.
@MainActor
final class DownloadPromptController: NSObject, NSWindowDelegate {
    @Observable
    final class Model {
        var candidate: DownloadCandidate
        var fileName: String
        var folder: URL
        var quality: MediaQuality = .p1080
        /// Set when a browser extension saw what the page was playing, in which case these are
        /// the real formats and the helper's presets are beside the point.
        var streamOptions: [StreamOption] = []
        var selectedOption: StreamOption?
        /// Chosen here as well as in Settings, because this is where a user lands after a
        /// download was blocked — and the message that sent them here names this control.
        var cookies: MediaCookieSource = .none
        var byteSize: Int64?
        /// Title of a media page, once the helper has looked it up.
        var title: String?
        var isResolving = false
        /// The chosen quality may only exist as separate video and audio streams, and joining
        /// them needs a tool the user may not have.
        var canMerge = true
        /// No helper on the machine at all. The prompt then exists to say so.
        var helperIsMissing = false
        /// Typing the address in, because detection guessed wrong or had nothing to guess from.
        var isManual = false
        var urlText = ""
        /// A probe is in flight for what was typed.
        var isProbing = false
        /// Set once a typed address has been looked at and found to be something.
        var probed: DownloadCandidate?
        /// The address is a web page and there is nothing installed to get media out of it, so
        /// what would download is its markup. Worth saying before it happens.
        var isPageWithoutHelper = false
        /// The still frame the page uses to represent itself. Decoration, and treated as such:
        /// it arrives late, or not at all, and nothing waits for it.
        var poster: NSImage?

        @ObservationIgnored var onURLChanged: ((String) -> Void)?

        @ObservationIgnored var onConfirm: (() -> Void)?
        @ObservationIgnored var onCancel: (() -> Void)?
        @ObservationIgnored var onChooseFolder: (() -> Void)?
        @ObservationIgnored var folderOptions: [URL] = []

        init(candidate: DownloadCandidate, folder: URL) {
            self.candidate = candidate
            self.fileName = candidate.fileName
            self.folder = folder
            self.byteSize = candidate.byteSize
            self.streamOptions = candidate.streamOptions
            self.selectedOption = candidate.streamOptions.first
            if let first = candidate.streamOptions.first { self.byteSize = first.byteSize }
        }

        var isMedia: Bool { candidate.transport == .mediaTool || !streamOptions.isEmpty }

        /// The formats came from the page itself, so nothing has to be installed to pick one.
        var hasSniffedOptions: Bool { !streamOptions.isEmpty }

        /// Without `ffmpeg` the helper can only ask for a single ready-made file, and that is
        /// the format the big sites now refuse. Worth saying before the download, not after.
        var showsMergeWarning: Bool {
            isMedia && !hasSniffedOptions && !helperIsMissing && quality.needsMerger && !canMerge
        }

        var canDownload: Bool {
            guard !helperIsMissing else { return false }
            guard isManual else { return true }
            // Nothing to download until the address is at least a web address.
            return LinkWatcher.singleWebURL(in: urlText) != nil
        }
    }

    /// Called when the user commits.
    var onConfirm: ((DownloadRequest) -> Void)?

    private let store: DownloadStore
    private let preferences: Preferences
    private let frontmostTracker: FrontmostApplicationTracker

    private var panel: NSPanel?
    private var model: Model?
    private var keyMonitor: Any?
    private var resolveTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var posterTask: Task<Void, Never>?
    /// The folder dialog takes key away from this panel, and losing key normally dismisses
    /// it — which would tear down the very prompt the folder is being chosen for.
    private var isChoosingFolder = false

    private static let panelSize = CGSize(width: 470, height: 360)
    private static let manualPanelSize = CGSize(width: 470, height: 380)
    /// Long enough that typing is not interrupted by a probe on every keystroke.
    private static let probeDelay: Duration = .milliseconds(700)

    init(store: DownloadStore, preferences: Preferences, frontmostTracker: FrontmostApplicationTracker) {
        self.store = store
        self.preferences = preferences
        self.frontmostTracker = frontmostTracker
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Presentation

    /// One prompt at a time. A second link arriving while the first is still on screen is
    /// dropped rather than queued: a stack of dialogs is not a feature.
    func show(_ candidate: DownloadCandidate) {
        guard !isVisible else { return }
        let model = makeModel(for: candidate)
        present(model, size: Self.panelSize)
        if candidate.transport == .mediaTool { resolveMediaTitle(candidate) }
        if model.isMedia { loadPoster(for: candidate) }
    }

    /// Fetches the page's own still frame for the panel's background.
    ///
    /// A prompt for a video that shows a grey icon says nothing about what is about to be
    /// downloaded; the frame says all of it. It is never waited on — the panel is fully usable
    /// before it arrives, and just as usable if it never does.
    private func loadPoster(for candidate: DownloadCandidate) {
        posterTask?.cancel()
        let page = candidate.url
        let headers = candidate.headers

        posterTask = Task { [weak self] in
            let image = await MediaPoster.image(for: page, headers: headers)
            guard let self, let model, !Task.isCancelled, let image else { return }
            model.poster = image
        }
    }

    private func makeModel(for candidate: DownloadCandidate) -> Model {
        let model = Model(candidate: candidate, folder: store.folder(for: candidate.kind))
        model.folderOptions = folderOptions(for: candidate.kind)
        model.quality = preferences.preferredMediaQuality
        model.cookies = preferences.mediaCookieSource
        model.canMerge = MediaTool.hasMerger()
        // Sniffed formats need no helper at all: the page already produced the URLs.
        model.helperIsMissing = candidate.streamOptions.isEmpty
            && candidate.transport == .mediaTool
            && MediaTool.resolve(configuredPath: preferences.mediaToolPath) == nil
        model.onConfirm = { [weak self] in self?.confirm() }
        model.onCancel = { [weak self] in self?.hide() }
        model.onChooseFolder = { [weak self] in self?.chooseFolder() }
        return model
    }

    private func present(_ model: Model, size: CGSize) {
        self.model = model
        frontmostTracker.remember()

        let panel = makePanel(model: model)
        self.panel = panel
        FloatingPanel.center(panel, size: size)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyMonitor()
    }

    /// Opens the prompt with an address field rather than a guess.
    func showManualEntry(prefilled: URL?) {
        guard !isVisible else { return }

        var candidate = DownloadCandidate(
            url: prefilled ?? URL(string: "https://")!,
            fileName: "",
            kind: .other,
            byteSize: nil,
            isResumable: false,
            transport: .http,
            title: nil
        )
        if let prefilled { candidate.fileName = LinkProbe.fileName(from: nil, url: prefilled) }

        let model = makeModel(for: candidate)
        model.isManual = true
        model.urlText = prefilled?.absoluteString ?? ""
        model.onURLChanged = { [weak self] text in self?.scheduleProbe(text) }
        present(model, size: Self.manualPanelSize)

        if prefilled != nil { scheduleProbe(model.urlText) }
    }

    /// Looks at what has been typed once it has stopped changing, and fills in what it learns.
    private func scheduleProbe(_ text: String) {
        probeTask?.cancel()
        guard let url = LinkWatcher.singleWebURL(in: text) else {
            model?.isProbing = false
            model?.probed = nil
            model?.isPageWithoutHelper = false
            return
        }

        model?.isProbing = true
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.probeDelay)
            guard !Task.isCancelled else { return }
            await self?.identify(url, typed: text)
        }
    }

    /// Works out what was typed, and rearranges the prompt to match.
    ///
    /// A pasted YouTube address is a page, and a page fetched as a file is a file full of HTML.
    /// So a media page becomes a media download here — and any page at all does when the helper
    /// is installed, because it handles a great many more sites than a host list ever could.
    private func identify(_ url: URL, typed text: String) async {
        let hasHelper = MediaTool.resolve(configuredPath: preferences.mediaToolPath) != nil

        if MediaTool.isMediaPage(url) {
            guard isStillTyping(text) else { return }
            switchToMedia(url, helperIsMissing: !hasHelper)
            return
        }

        let outcome = await LinkProbe.inspect(url)
        guard let model, isStillTyping(text) else { return }
        model.isProbing = false

        switch outcome {
        case .file(let probed):
            model.candidate = probed
            model.probed = probed
            model.byteSize = probed.byteSize
            model.fileName = probed.fileName
            model.folder = store.folder(for: probed.kind)
            model.isPageWithoutHelper = false

        case .page:
            // The helper knows far more sites than the host list does, so an unrecognised page
            // is worth handing to it rather than saving as markup.
            if hasHelper {
                switchToMedia(url, helperIsMissing: false)
            } else {
                model.probed = nil
                model.isPageWithoutHelper = true
                if model.fileName.isEmpty {
                    model.fileName = LinkProbe.fileName(from: nil, url: url)
                }
            }

        case .unreachable:
            // Unreachable is not the same as invalid: plenty of links refuse to be asked about
            // and download perfectly on a real request.
            model.probed = nil
            model.isPageWithoutHelper = false
            if model.fileName.isEmpty {
                model.fileName = LinkProbe.fileName(from: nil, url: url)
            }
        }
    }

    /// Whether the answer still belongs to what is in the field.
    private func isStillTyping(_ text: String) -> Bool {
        !Task.isCancelled && model?.urlText == text
    }

    private func switchToMedia(_ url: URL, helperIsMissing: Bool) {
        guard let model else { return }
        var candidate = DownloadCoordinator.mediaCandidate(for: url)
        candidate.title = model.candidate.title

        model.candidate = candidate
        model.probed = candidate
        model.isProbing = false
        model.isPageWithoutHelper = false
        model.helperIsMissing = helperIsMissing
        model.byteSize = nil
        model.fileName = candidate.fileName
        model.folder = store.folder(for: .video)

        loadPoster(for: candidate)
        guard !helperIsMissing else { return }
        resolveMediaTitle(candidate)
    }

    func hide() {
        resolveTask?.cancel()
        resolveTask = nil
        probeTask?.cancel()
        probeTask = nil
        posterTask?.cancel()
        posterTask = nil
        stopKeyMonitor()
        panel?.orderOut(nil)
        panel = nil
        model = nil
        frontmostTracker.restore()
    }

    private func confirm() {
        guard let model, model.canDownload else { return }
        let name = model.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = model.candidate

        // A typed address replaces the one the prompt opened with, and whatever the probe
        // managed to learn about it comes along.
        if model.isManual, let url = LinkWatcher.singleWebURL(in: model.urlText) {
            candidate = model.probed ?? candidate
            candidate.url = url
            if candidate.fileName.isEmpty {
                candidate.fileName = LinkProbe.fileName(from: nil, url: url)
            }
        }
        candidate.title = model.title
        candidate.byteSize = model.byteSize

        onConfirm?(DownloadRequest(
            candidate: candidate,
            fileName: name.isEmpty ? candidate.fileName : name,
            folder: model.folder,
            quality: model.hasSniffedOptions ? nil : (model.isMedia ? model.quality : nil),
            streamOption: model.selectedOption
        ))
        if model.isMedia, !model.hasSniffedOptions {
            preferences.preferredMediaQuality = model.quality
            preferences.mediaCookieSource = model.cookies
        }
        hide()
    }

    /// The folders offered without opening a file dialog: the download folder, and the
    /// sub-folder for this kind when sorting is on.
    private func folderOptions(for kind: DownloadKind) -> [URL] {
        var options = [store.downloadFolder]
        let sorted = store.downloadFolder.appendingPathComponent(kind.folderName, isDirectory: true)
        if !options.contains(sorted) { options.append(sorted) }
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            options.append(desktop)
        }
        return options
    }

    private func chooseFolder() {
        isChoosingFolder = true
        defer { isChoosingFolder = false }

        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.canCreateDirectories = true
        dialog.allowsMultipleSelection = false
        dialog.directoryURL = model?.folder
        dialog.prompt = String(localized: "Choose", comment: "Folder picker confirm button")

        let response = dialog.runModal()
        panel?.makeKeyAndOrderFront(nil)
        guard response == .OK, let url = dialog.url else { return }

        model?.folder = url
        if let model, !model.folderOptions.contains(url) { model.folderOptions.append(url) }
    }

    /// Fills in the page's real title, and its size where the helper knows it. Until it
    /// arrives the prompt shows the address, which is honest about what is known.
    private func resolveMediaTitle(_ candidate: DownloadCandidate) {
        guard let tool = MediaTool.resolve(configuredPath: preferences.mediaToolPath) else { return }
        model?.isResolving = true
        // Read here rather than inside the task: what the helper is asked is settled the moment
        // the prompt opens, and the closure then holds a value instead of a reference.
        let cookies = preferences.mediaCookieSource

        resolveTask = Task { [weak self] in
            let info = await MediaTool.pageInfo(
                for: candidate.url,
                tool: tool,
                cookies: cookies
            )
            guard let self, let model, !Task.isCancelled else { return }
            model.isResolving = false
            guard let info else { return }
            model.title = info.title
            model.fileName = LinkProbe.sanitize(info.title)
        }
    }

    // MARK: - Window

    private func makePanel(model: Model) -> NSPanel {
        let panel = FloatingPanel.make(
            size: Self.panelSize,
            title: String(localized: "Download", comment: "Floating panel title"),
            content: DownloadPromptView(model: model)
        )
        panel.delegate = self
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isChoosingFolder else { return }
        // Clicking away is a decision too — the link stays on the clipboard either way.
        hide()
    }

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }

            switch Int(event.keyCode) {
            case kVK_Escape:
                self.hide()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.confirm()
                return nil
            default:
                return event
            }
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - View

private struct DownloadPromptView: View {
    @Bindable var model: DownloadPromptController.Model

    @FocusState private var isURLFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: Metrics.spacing) {
                if model.isManual, model.helperIsMissing {
                    urlField
                    missingHelper
                } else if model.isManual {
                    urlField
                    nameField
                    if model.isMedia {
                        qualityPicker
                        cookiePicker
                    }
                    folderRow
                    if model.isPageWithoutHelper { pageWarning }
                } else if model.helperIsMissing {
                    missingHelper
                } else {
                    nameField
                    if model.hasSniffedOptions {
                        streamPicker
                    } else if model.isMedia {
                        qualityPicker
                        cookiePicker
                    }
                    folderRow
                    if model.showsMergeWarning { mergeWarning }
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            Divider().opacity(0.5)
            footer
        }
        .background(background)
        // Over a still frame the panel is a dark surface whatever the system is set to, so the
        // system's own text and control colours have to resolve for one.
        .environment(\.colorScheme, showsPoster ? .dark : .light)
        .preferredColorScheme(showsPoster ? .dark : nil)
    }

    /// Whether the page's own frame is behind everything. Reduce Transparency turns it off: the
    /// panel is then a plain surface, which is the point of the setting.
    private var showsPoster: Bool { model.poster != nil && !reduceTransparency }

    private var background: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)

            if let poster = model.poster, !reduceTransparency {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Blurred to the point of being a colour field: it is there to say what this
                    // is about, not to be looked at.
                    .blur(radius: 36, opaque: true)
                    .overlay {
                        LinearGradient(
                            colors: [.black.opacity(0.62), .black.opacity(0.78)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .transition(.opacity)
            }
        }
        .clipped()
        .motion(Motion.fluid, value: model.poster != nil)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // The frame itself, crisp and small, where the icon would otherwise be.
            if let poster = model.poster, !reduceTransparency {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 30)
                    .clipShape(.rect(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else {
                Image(systemName: model.candidate.kind.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(Accent.clipboard.gradient)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.isManual
                     ? "Download a link"
                     : (model.isMedia ? "Download media" : "Download file"))
                    .font(.headline)
                Text(model.isManual
                     ? String(localized: "Paste or type an address", comment: "Manual download prompt subtitle")
                     : model.candidate.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if model.isResolving {
                ProgressView()
                    .controlSize(.small)
                    .help("Looking up what is on the page")
            } else if let byteSize = model.byteSize {
                Text(Format.bytes(byteSize))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The way back when detection got it wrong. Focused on open, so a paste and Return is the
    /// whole interaction.
    private var urlField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Address")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("https://", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .focused($isURLFocused)
                    .onChange(of: model.urlText) { _, text in model.onURLChanged?(text) }

                if model.isProbing {
                    ProgressView().controlSize(.small)
                } else if model.probed != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .onAppear { isURLFocused = true }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Save as")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("File name", text: $model.fileName)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                // The extension is the helper's to decide once it knows the format it got.
                .disabled(model.isMedia && model.isResolving)
        }
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quality")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Quality", selection: $model.quality) {
                ForEach(MediaQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// The formats the page was actually seen playing. No presets and no helper: these are the
    /// site's own streams, already signed, exactly as the player asked for them.
    private var streamPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quality")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Quality", selection: $model.selectedOption) {
                ForEach(model.streamOptions) { option in
                    Text(option.label).tag(Optional(option))
                }
            }
            .labelsHidden()
            .onChange(of: model.selectedOption) { _, option in
                guard let option else { return }
                model.byteSize = option.byteSize
                model.fileName = Self.rename(model.fileName, to: option.fileExtension)
            }

            if model.selectedOption?.needsMerge == true {
                Text("This site serves picture and sound apart; ffmpeg joins them as they arrive.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The extension it will actually be, so the name in the field is not a promise the download
    /// cannot keep.
    private static func rename(_ name: String, to extension: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : "\(base).\(`extension`)"
    }

    /// Saving a page's markup is almost never what someone pasting a link had in mind.
    private var pageWarning: some View {
        Label(
            "This address is a web page, so its source is what would be saved. Install yt-dlp and MagicPlus can pull the media out of it instead.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The one control that decides whether a big site lets the download finish at all.
    private var cookiePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cookies")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("Cookies", selection: $model.cookies) {
                    ForEach(MediaCookieSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .labelsHidden()
                .fixedSize()

                if model.cookies == .none {
                    Text("YouTube often blocks the download partway without a signed-in session.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Where")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.folderOptions, id: \.self) { url in
                        Button(url.lastPathComponent) { model.folder = url }
                    }
                } label: {
                    Label(model.folder.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button("Choose…") { model.onChooseFolder?() }
                    .controlSize(.small)
            }
        }
    }

    /// Not a failure, and not silence either: the one thing standing between this page and a
    /// download is a tool the user has to install themselves, so the prompt hands it over.
    private var missingHelper: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Label("The media helper is not installed", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("MagicPlus ships no site extractors. Install `yt-dlp` and this page downloads like anything else, in the same queue.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(MediaTool.installCommand)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))

            HStack(spacing: 8) {
                Button("Install…") { MediaTool.runInstaller() }
                    .buttonStyle(.borderedProminent)

                Button("Copy install command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MediaTool.installCommand, forType: .string)
                }
            }

            Text(MediaTool.homebrew() == nil
                ? "Homebrew is not installed either — Install… opens brew.sh, which is one command."
                : "Install… opens a Terminal window and runs it, so you can watch it and stop it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mergeWarning: some View {
        Label(
            "ffmpeg is missing, so only single-file formats can be asked for — and YouTube refuses those on most videos. Install it and video downloads work; audio only works either way.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(keys: "esc", label: "Cancel")
            Spacer()
            Button(model.helperIsMissing ? "Close" : "Cancel") { model.onCancel?() }
            if !model.helperIsMissing {
                Button("Download") { model.onConfirm?() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canDownload)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
