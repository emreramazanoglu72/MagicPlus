//
//  NotchView.swift
//  tabmenu
//

import SwiftUI
import UniformTypeIdentifiers

/// Body of the expanded island: tabs and whichever pane is selected.
struct NotchPanelContent: View {
    let model: NotchModel
    let morph: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabHighlight

    var body: some View {
        VStack(spacing: 10) {
            tabBar
            content
        }
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(NotchTab.allCases) { tab in
                Button {
                    withMotion(Motion.fluid, reduceMotion: reduceMotion) { model.selectedTab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                            .symbolEffect(.bounce, value: model.selectedTab == tab)
                        Text(tab.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(model.selectedTab == tab ? .white : .white.opacity(0.45))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        if model.selectedTab == tab {
                            Capsule()
                                .fill(.white.opacity(0.14))
                                .matchedGeometryEffect(id: "notchTab", in: tabHighlight)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(model.selectedTab == tab ? [.isSelected, .isButton] : .isButton)
            }

            Spacer()

            if model.selectedTab == .shelf, !model.shelf.files.isEmpty {
                ShareLink(items: model.shelf.urls) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.12), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Share or AirDrop these files")

                IslandIconButton(systemImage: "trash", help: "Empty the shelf") {
                    model.shelf.clear()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedTab {
        case .media:
            MediaPane(model: model)
        case .mixer:
            MixerPane(mixer: model.mixer, brightness: model.brightness)
        case .agenda:
            AgendaPane(model: model)
        case .shelf:
            ShelfPane(model: model)
        case .mirror:
            CameraMirrorView(isActive: model.selectedTab == .mirror)
                .frame(height: 170)
                .clipShape(.rect(cornerRadius: 14))
                .accessibilityLabel("Camera mirror")
        }
    }
}

// MARK: - Media

private struct MediaPane: View {
    let model: NotchModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkTile(image: model.artwork, size: 60, cornerRadius: 12)
                    if let icon = sourceIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .offset(x: 6, y: 6)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.nowPlaying?.title ?? "Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(model.nowPlaying?.artist ?? "Controls still drive whatever is playing")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    Text(model.nowPlaying?.source.displayName ?? "Media keys")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            if let progress = model.nowPlaying?.progress {
                VStack(spacing: 3) {
                    LevelBar(value: progress, tint: .white, height: 3)
                    HStack {
                        Text(NowPlaying.timestamp(model.nowPlaying?.position ?? 0))
                        Spacer()
                        Text(NowPlaying.timestamp(model.nowPlaying?.duration ?? 0))
                    }
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue(Format.percent(progress))
            }

            HStack(spacing: 10) {
                IslandIconButton(systemImage: "backward.fill", help: "Previous", action: model.previousTrack)
                IslandIconButton(
                    systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                    help: "Play or pause",
                    isPrimary: true,
                    action: model.playPause
                )
                IslandIconButton(systemImage: "forward.fill", help: "Next", action: model.nextTrack)

                Spacer()

                HStack(spacing: 6) {
                    outputDeviceMenu
                    DraggableLevelBar(value: model.outputVolume) { model.setVolume($0) }
                        .frame(width: 88)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Output volume")
                .accessibilityValue(Format.percent(model.outputVolume))
            }
        }
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
            Image(systemName: model.outputVolume < 0.01 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the output device")
        .accessibilityLabel("Output device")
    }
}

/// Volume slider styled for the black island; the system control looks foreign here.
private struct DraggableLevelBar: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: max(3, proxy.size.width * value.clampedToUnitRange))
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onChange(min(max(gesture.location.x / proxy.size.width, 0), 1))
                    }
            )
        }
        .frame(height: 5)
    }
}

struct IslandIconButton: View {
    let systemImage: String
    let help: String
    var isPrimary = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 12 : 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 1 : 0.8))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: isPrimary ? 30 : 26, height: isPrimary ? 30 : 26)
                .background(.white.opacity(isHovered ? 0.2 : 0.12), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Agenda

private struct AgendaPane: View {
    let model: NotchModel

    private var calendar: CalendarService { model.calendar }

    var body: some View {
        Group {
            if !calendar.isAuthorized {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Allow Calendar access to see your next meeting")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                    Button("Allow") { calendar.requestAccess() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.white, in: .capsule)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if calendar.events.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Nothing scheduled")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 6) {
                    ForEach(calendar.events.prefix(3)) { event in
                        EventRow(event: event) { calendar.join(event) }
                    }
                }
            }
        }
        .frame(minHeight: 92)
    }
}

private struct EventRow: View {
    let event: AgendaEvent
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColor)
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(event.startDate.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10).monospacedDigit())
                    Text("·")
                    Text(event.countdownLabel())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(event.isInProgress ? .green : .white.opacity(0.55))
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 6)

            if event.meetingURL != nil {
                Button(action: onJoin) {
                    Text("Join")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.white, in: .capsule)
                }
                .buttonStyle(.plain)
                .help("Open the meeting link")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(event.countdownLabel())")
    }
}

// MARK: - Shelf

private struct ShelfPane: View {
    let model: NotchModel

    private var shelf: ShelfStore { model.shelf }

    var body: some View {
        Group {
            if shelf.files.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.5))
                        .symbolEffect(.bounce, value: model.isDropTargeted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop files here")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Drag them out again whenever you need them")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(model.isDropTargeted ? 0.14 : 0.07), in: .rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: .init(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.white.opacity(0.25))
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(shelf.files) { file in
                            ShelfTile(file: file, store: shelf)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                .frame(height: 88)
            }
        }
    }
}

private struct ShelfTile: View {
    let file: ShelfFile
    let store: ShelfStore

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: file.icon)
                .resizable()
                .frame(width: 38, height: 38)
            Text(file.name)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 66)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 5)
        .background(.white.opacity(isHovered ? 0.16 : 0.07), in: .rect(cornerRadius: 11, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button {
                    store.remove(file)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 15, height: 15)
                        .background(.white, in: .circle)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Remove \(file.name)")
            }
        }
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .draggable(file.url) {
            Image(nsImage: file.icon).resizable().frame(width: 42, height: 42)
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
