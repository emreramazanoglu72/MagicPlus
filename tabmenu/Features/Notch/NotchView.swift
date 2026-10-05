//
//  NotchView.swift
//  tabmenu
//

import SwiftUI
import UniformTypeIdentifiers

/// Body of the expanded island: the pane switcher and whichever pane is selected.
///
/// Every pane is the same height. A panel that grew and shrank as the user moved between tabs
/// would move the very control they are aiming at, and it is the single thing that made the
/// old layout feel unfinished.
struct NotchPanelContent: View {
    @Bindable var model: NotchModel
    let morph: Namespace.ID

    var body: some View {
        VStack(spacing: Island.Space.m) {
            IslandTabRail(
                selection: $model.selectedTab,
                tabs: model.visibleTabs,
                trailing: AnyView(paneActions)
            )
            pane
        }
    }

    /// Fixed slot, always present: buttons that appear and disappear must not resize the rail
    /// beside them.
    @ViewBuilder
    private var paneActions: some View {
        switch model.selectedTab {
        case .shelf: shelfActions
        case .downloads: downloadActions
        default: emptyActions
        }
    }

    private var emptyActions: some View {
        Color.clear.frame(width: 64, height: 28)
    }

    private var shelfActions: some View {
        HStack(spacing: Island.Space.xs) {
            if !model.shelf.files.isEmpty {
                ShareLink(items: model.shelf.urls) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Island.Ink.primary.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(Island.Fill.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .help("Share or AirDrop these files")

                IslandIconButton(systemImage: "trash", help: "Empty the shelf") {
                    model.shelf.clear()
                }
            }
        }
        .frame(width: 64, alignment: .trailing)
        .motion(Motion.snappy, value: model.shelf.files.count)
    }

    /// The two things worth doing to a whole queue: stop it, and tidy up after it.
    private var downloadActions: some View {
        let store = model.downloads

        return HStack(spacing: Island.Space.xs) {
            IslandIconButton(
                systemImage: "plus",
                help: String(localized: "Paste a link", comment: "Opens the manual download prompt"),
                size: 28,
                action: model.enterLinkManually
            )

            if store.hasActivity {
                IslandIconButton(systemImage: "pause.circle", help: String(localized: "Pause every download", comment: "Downloads pane action")) {
                    store.pauseAll()
                }
            } else if store.items.contains(where: { $0.state == .paused || $0.state == .failed }) {
                IslandIconButton(systemImage: "play.circle", help: String(localized: "Resume every download", comment: "Downloads pane action")) {
                    store.resumeAll()
                }
            }

            if store.items.contains(where: \.state.isFinished) {
                IslandIconButton(systemImage: "trash", help: String(localized: "Clear finished downloads", comment: "Downloads pane action")) {
                    store.clearFinished()
                }
            }
        }
        .frame(width: 96, alignment: .trailing)
        .motion(Motion.snappy, value: store.items.count)
    }

    @ViewBuilder
    private var pane: some View {
        switch model.selectedTab {
        case .media:
            IslandPane(alignment: .center) { MediaPane(model: model) }
        case .mixer:
            IslandPane(scrolls: true) { MixerPane(mixer: model.mixer, brightness: model.brightness) }
        case .agenda:
            IslandPane(scrolls: true) { AgendaPane(model: model) }
        case .shelf:
            IslandPane { ShelfPane(model: model) }
        case .downloads:
            IslandPane { DownloadsPane(model: model, onAddLink: model.enterLinkManually) }
        case .mirror:
            IslandPane {
                CameraMirrorView(isActive: model.selectedTab == .mirror)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(.rect(cornerRadius: Island.Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Island.Radius.card, style: .continuous)
                            .strokeBorder(Island.hairline, lineWidth: 1)
                    }
                    .accessibilityLabel("Camera mirror")
            }
        }
    }
}

// MARK: - Media

private struct MediaPane: View {
    let model: NotchModel

    var body: some View {
        VStack(spacing: Island.Space.m) {
            header
            scrubber
            transport
            volume
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Island.Space.m)
        .background { cover }
    }

    /// The cover, filling the pane rather than sitting in a square beside the words.
    ///
    /// Blurred and darkened, because it is behind text that has to stay readable — but far less
    /// than a background needs to be when it is only decoration. What is playing is worth
    /// looking at, and a 68pt thumbnail is not looking at it.
    private var cover: some View {
        // `Color.clear` takes the size on offer and the picture is clipped to it. Left to itself,
        // an image filling its frame decides how big that frame is, and a cover behind one pane
        // ends up drawn over the tab rail above it.
        Color.clear
            .overlay {
                if let artwork = model.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 12, opaque: true)
                        .overlay {
                            LinearGradient(
                                colors: [.black.opacity(0.45), .black.opacity(0.78)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .transition(.opacity)
                } else {
                    Island.Fill.subtle
                }
            }
            .clipShape(.rect(cornerRadius: Island.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Island.Radius.card, style: .continuous)
                    .strokeBorder(Island.hairline, lineWidth: 1)
            }
            .motion(Motion.fluid, value: model.artwork != nil)
            // Decoration must never take a click. A background that does is a background that
            // swallows the controls above it the moment it grows a pixel past its pane.
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: Island.Space.m) {
            // The cover twice over: sharp and small here, spread out and blurred behind. The
            // small one is the thing itself; the large one is the mood.
            ZStack(alignment: .bottomTrailing) {
                ArtworkTile(image: model.artwork, size: 62, cornerRadius: Island.Radius.card)
                if let icon = sourceIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .clipShape(.rect(cornerRadius: 5, style: .continuous))
                        .padding(2)
                        .background(.black, in: .rect(cornerRadius: 7, style: .continuous))
                        .offset(x: 5, y: 5)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.nowPlaying?.title ?? String(localized: "Nothing playing", comment: "Media pane, no track"))
                    .font(Island.Text.title)
                    .foregroundStyle(Island.Ink.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.nowPlaying?.artist ?? String(localized: "Controls still drive whatever is playing", comment: "Media pane, no track"))
                    .font(Island.Text.body)
                    .foregroundStyle(Island.Ink.secondary)
                    .lineLimit(1)

                // Always present, so the block keeps its height whether or not a player is
                // reporting: with nothing playing, the media keys are still what drives this.
                Text(model.nowPlaying?.source.displayName ?? String(localized: "Media keys", comment: "Media pane, no track"))
                    .font(Island.Text.caption)
                    .foregroundStyle(Island.Ink.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 62)
        // Over a picture, text and artwork both need something under them that is not the
        // picture.
        .shadow(color: .black.opacity(model.artwork == nil ? 0 : 0.55), radius: 7)
    }

    /// Kept in the layout even with nothing to show, so the transport row never moves.
    private var scrubber: some View {
        let progress = model.nowPlaying?.progress

        return VStack(spacing: Island.Space.xs) {
            LevelBar(value: progress ?? 0, tint: Island.Ink.primary.opacity(0.9), height: 4)
            HStack {
                Text(NowPlaying.timestamp(model.nowPlaying?.position ?? 0))
                Spacer()
                Text(NowPlaying.timestamp(model.nowPlaying?.duration ?? 0))
            }
            .font(Island.Text.numericSmall)
            .foregroundStyle(Island.Ink.tertiary)
        }
        // Pinned rather than left to the stack: the bar's geometry reader would otherwise
        // take whatever height is going and push the transport to the floor.
        .frame(height: 22)
        .opacity(progress == nil ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(Format.percent(progress ?? 0))
        .accessibilityHidden(progress == nil)
    }

    private var transport: some View {
        HStack(spacing: Island.Space.l) {
            Spacer(minLength: 0)
            IslandIconButton(systemImage: "backward.fill", help: "Previous", action: model.previousTrack)
            IslandIconButton(
                systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                help: "Play or pause",
                isPrimary: true,
                action: model.playPause
            )
            IslandIconButton(systemImage: "forward.fill", help: "Next", action: model.nextTrack)
            Spacer(minLength: 0)
        }
        .frame(height: 36)
    }

    private var volume: some View {
        HStack(spacing: Island.Space.m) {
            outputDeviceMenu

            IslandSlider(value: model.outputVolume) { model.setVolume($0) }

            Text(Format.percent(model.outputVolume))
                .font(Island.Text.numeric)
                .foregroundStyle(Island.Ink.secondary)
                .contentTransition(.numericText())
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Output volume")
        .accessibilityValue(Format.percent(model.outputVolume))
    }

    private var sourceIcon: NSImage? {
        guard let bundleIdentifier = model.nowPlaying?.source.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Where the audio goes — the fix for a call app hijacking the output.
    private var outputDeviceMenu: some View {
        Menu {
            ForEach(model.outputDevices) { device in
                Button {
                    model.selectOutputDevice(device)
                } label: {
                    if device.id == model.currentOutputDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: Island.Space.xs) {
                Image(systemName: model.outputVolume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Island.Ink.secondary)
            .frame(height: 24)
            .padding(.horizontal, Island.Space.s)
            .background(Island.Fill.regular, in: .capsule)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the output device")
        .accessibilityLabel("Output device")
    }
}

// MARK: - Agenda

private struct AgendaPane: View {
    let model: NotchModel

    private var calendar: CalendarService { model.calendar }

    var body: some View {
        if !calendar.isAuthorized {
            IslandEmptyState(
                systemImage: "calendar.badge.clock",
                title: "Calendar access is off",
                message: "Allow it and your next meetings appear here, with a button to join them."
            ) {
                IslandChipButton(title: "Allow", isProminent: true) { calendar.requestAccess() }
            }
        } else if calendar.events.isEmpty {
            IslandEmptyState(
                systemImage: "checkmark.circle",
                title: "Nothing scheduled",
                message: "The rest of the day is yours."
            )
        } else {
            VStack(spacing: Island.Space.s) {
                ForEach(calendar.events.prefix(4)) { event in
                    EventRow(event: event) { calendar.join(event) }
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: AgendaEvent
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: Island.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(Island.Text.numeric)
                    .foregroundStyle(Island.Ink.primary)
                Text(event.countdownLabel())
                    .font(Island.Text.caption)
                    .foregroundStyle(event.isInProgress ? Island.Signal.success : Island.Ink.tertiary)
            }
            .frame(width: 62, alignment: .leading)

            Capsule()
                .fill(event.calendarColor)
                .frame(width: 3, height: 30)

            Text(event.title)
                .font(Island.Text.body)
                .foregroundStyle(Island.Ink.primary)
                .lineLimit(2)

            Spacer(minLength: Island.Space.xs)

            if event.meetingURL != nil {
                IslandChipButton(title: "Join", action: onJoin)
                    .help("Open the meeting link")
            }
        }
        .padding(.horizontal, Island.Space.m)
        .padding(.vertical, Island.Space.s)
        .background(Island.Fill.subtle, in: .rect(cornerRadius: Island.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(event.countdownLabel())")
    }
}

// MARK: - Shelf

private struct ShelfPane: View {
    let model: NotchModel

    private var shelf: ShelfStore { model.shelf }

    private static let tileWidth: CGFloat = 76
    private static let rowHeight: CGFloat = 84

    var body: some View {
        if shelf.files.isEmpty {
            dropZone
        } else {
            ScrollView(.horizontal) {
                LazyHGrid(
                    rows: [
                        GridItem(.fixed(Self.rowHeight), spacing: Island.Space.s),
                        GridItem(.fixed(Self.rowHeight), spacing: Island.Space.s)
                    ],
                    spacing: Island.Space.s
                ) {
                    ForEach(shelf.files) { file in
                        ShelfTile(file: file, store: shelf, width: Self.tileWidth)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dropZone: some View {
        VStack(spacing: Island.Space.s) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(model.isDropTargeted ? Island.Signal.info : Island.Ink.tertiary)
                .symbolEffect(.bounce, value: model.isDropTargeted)

            Text("Drop files here")
                .font(Island.Text.body)
                .foregroundStyle(Island.Ink.secondary)
            Text("Drag them out again whenever you need them")
                .font(Island.Text.caption)
                .foregroundStyle(Island.Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            model.isDropTargeted ? Island.Fill.regular : Island.Fill.subtle,
            in: .rect(cornerRadius: Island.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Island.Radius.card, style: .continuous)
                .strokeBorder(
                    model.isDropTargeted ? Island.Signal.info : Island.Ink.tertiary.opacity(0.5),
                    style: .init(lineWidth: 1, dash: [5, 4])
                )
        }
        .motion(Motion.snappy, value: model.isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop files here")
    }
}

private struct ShelfTile: View {
    let file: ShelfFile
    let store: ShelfStore
    let width: CGFloat

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: Island.Space.xs) {
            Image(nsImage: file.icon)
                .resizable()
                .frame(width: 40, height: 40)

            Text(file.name)
                .font(Island.Text.caption)
                .foregroundStyle(Island.Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width - Island.Space.m)
        }
        .frame(width: width, height: 78)
        .background(
            isHovered ? Island.Fill.strong : Island.Fill.subtle,
            in: .rect(cornerRadius: Island.Radius.tile, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button {
                    store.remove(file)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Island.Ink.inverted)
                        .frame(width: 16, height: 16)
                        .background(Island.Fill.solid, in: .circle)
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Remove \(file.name)")
            }
        }
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .draggable(file.url) {
            Image(nsImage: file.icon).resizable().frame(width: 44, height: 44)
        }
        .onTapGesture(count: 2) { store.open(file) }
        .contextMenu {
            Button("Open") { store.open(file) }
            Button("Reveal in Finder") { store.revealInFinder(file) }
            Divider()
            Button("Remove", role: .destructive) { store.remove(file) }
        }
        .help(file.url.path)
        .accessibilityLabel(file.name)
    }
}
