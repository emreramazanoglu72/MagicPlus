//
//  DockStripView.swift
//  MagicPlus
//

import AppKit
import SwiftUI

/// One strip along the edge: what is in front, what is running, what is playing, and the time.
///
/// The shape a bar like this has, in order: a button of our own, then the application in front with
/// the title of its window, then the running applications with their notification counts, then
/// playback, the trash, the volume, and a clock. Each of those already existed somewhere in this
/// app — the media controller, the audio service, the window lister, the dock's own tiles — so this
/// is mostly a matter of putting them on one line.
///
/// How it is drawn is the other half, and the answer is: as little as possible. There are no panels
/// behind the groups, no outlines, no rounded rectangles, no dividers. It went through a version
/// with all of those and they made it look like a settings window lying on its side — frames doing
/// the work that space should do. What separates the groups now is distance, what marks the icon
/// under the pointer is that it grows, and the only drawn line in the whole strip is a hairline of
/// light along the edge that faces the screen. Everything else is the icons themselves.
struct DockStripView: View {
    let model: DockModel
    /// The first button, with its own rectangle in window coordinates so the menu opens out of it.
    var onStart: (CGRect) -> Void
    /// Opening a tile, with the icon's own rectangle: a folder's contents open out of the folder.
    var onOpenTile: (DockTile, CGRect) -> Void
    var onMedia: (MediaCommand) -> Void
    /// The speaker, with its own rectangle so the slider opens out of it.
    var onVolume: (CGRect) -> Void
    /// Right-click on the bar itself: where it sits, and the way out.
    var onSetEdge: (DockStyle.Edge) -> Void
    var onOpenSettings: () -> Void
    var onDisable: () -> Void
    /// Reports which icon the pointer is over and where that icon is, in window coordinates, so the
    /// preview panel can open beside it. `nil` when the pointer leaves.
    var onHoverIcon: ((DockTile, CGRect)?) -> Void
    /// Files dropped on a tile. `true` if the tile did something with them, which is what tells
    /// the drag whether it landed.
    var onDrop: (DockTile, [URL]) -> Bool
    /// Clears the screen and puts it back.
    var onShowDesktop: () -> Void
    /// Files dropped on the assistant's button.
    var onDropOnAgent: ([URL]) -> Bool
    /// Whether the pointer is on the strip, for a bar that parks itself when it is not.
    var onHoverStrip: (Bool) -> Void

    /// The assistant button, with its own rectangle so the chat opens out of it. Drawn only when
    /// the model says so — a button whose only answer is "no API key is set" is not a button.
    var onAgent: (CGRect) -> Void
    /// Everything the macOS Dock offers behind a right-click, supplied by the controller because
    /// each answer needs something only it has.
    var menu: (DockTile, [SwitchableWindow]) -> DockTileMenu

    enum MediaCommand { case previous, playPause, next }

    @Environment(\.colorScheme) private var systemScheme

    private var style: DockStyle { model.style }
    private var iconSize: CGFloat { style.barIconSize }

    /// What the strip draws itself in — its own surface's appearance when it has one, otherwise the
    /// desktop's. See ``DockStyle/contentScheme``.
    private var scheme: ColorScheme { style.contentScheme ?? systemScheme }

    /// The colour of whatever is in front. Neutral when that app's icon has no colour worth
    /// borrowing, which keeps Terminal from tinting the bar an arbitrary hue.
    private var accent: Color {
        DockAccent.color(for: model.frontmostIcon, key: model.frontmostBundleIdentifier) ?? .white
    }

    var body: some View {
        HStack(spacing: 16) {
            StartButton(size: iconSize * 0.72, action: onStart)

            frontmost

            // Where the icons sit is a setting, and the bar used to ignore it — the picker in
            // Settings moved nothing. One spacer either side, or one of them, is the whole of it.
            if style.alignment != .leading { Spacer(minLength: 20) }

            appIcons

            if style.alignment != .trailing { Spacer(minLength: 20) }

            media

            systemItems

            showDesktop
        }
        .padding(.leading, 14)
        .padding(.trailing, 0)
        .frame(height: style.barHeight)
        .background { DockSurface(style: style, accent: accent) }
        // Whole-strip hover, which is all an auto-hiding bar needs: the sliver it parks itself down
        // to is part of this view, so reaching for the edge is already a hover on it. No global
        // mouse monitor, and nothing running when the bar is not hiding itself.
        .onHover { onHoverStrip($0) }
        .environment(\.colorScheme, scheme)
        .motion(Motion.fluid, value: model.frontmostBundleIdentifier)
        // Right-clicking the bar itself, rather than an icon on it: where it sits and the way out
        // are the two things you want when the answer is "not here".
        .contextMenu {
            Menu(String(localized: "Position", comment: "Bar menu")) {
                ForEach(DockStyle.Edge.allCases) { edge in
                    Button {
                        onSetEdge(edge)
                    } label: {
                        HStack {
                            Text(edge.title)
                            if style.edge == edge { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Divider()
            Button(String(localized: "Dock Settings…", comment: "Bar menu"), action: onOpenSettings)
            Button(String(localized: "Use the System Dock", comment: "Bar menu: switch the custom dock off"), action: onDisable)
        }
    }

    /// The titles of that application's windows, for its own menu. A right-click that lists what is
    /// open is the difference between a menu and a decoration.
    private func windowTitles(for tile: DockTile) -> [SwitchableWindow] {
        guard let identifier = tile.bundleIdentifier else { return [] }
        return model.windows.filter { $0.bundleIdentifier == identifier }
    }

    // MARK: - Segments

    /// The application in front, and the title of the window in front of it. The title is the part
    /// that makes this useful: an icon says which app, a title says which document.
    @ViewBuilder
    private var frontmost: some View {
        if !model.frontmostName.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.frontmostName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if !model.frontmostWindowTitle.isEmpty {
                    Text(model.frontmostWindowTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Everything the dock holds except the bin, which the bar keeps at its own end beside the
    /// volume and the clock.
    ///
    /// Pinned or running, in the order the dock lists them. It used to show only what was running,
    /// which meant the applications someone had deliberately kept in their dock were the ones it
    /// left out — a dock whose whole point is the icons you chose, showing you the ones you did not.
    private var barTiles: [DockTile] {
        var tiles = model.tiles
        guard let bin = tiles.lastIndex(where: { if case .trash = $0.kind { true } else { false } })
        else { return tiles }
        tiles.removeSubrange(bin...)
        // And the gap that was there to hold the bin apart from everything else.
        if let last = tiles.last, case .separator = last.kind { tiles.removeLast() }
        return tiles
    }

    private var appIcons: some View {
        HStack(spacing: style.spacing) {
            ForEach(barTiles) { tile in
                if case .separator = tile.kind {
                    // No line. A wider gap does the separating, the same as everywhere else here.
                    Color.clear.frame(width: style.spacing, height: 1)
                } else {
                    StripIcon(
                        tile: tile,
                        size: iconSize,
                        badge: tile.bundleIdentifier.flatMap { model.badges[$0] },
                        style: style,
                        isFrontmost: tile.bundleIdentifier == model.frontmostBundleIdentifier,
                        onOpen: { frame in onOpenTile(tile, frame) },
                        onHover: { frame in onHoverIcon(frame.map { (tile, $0) }) },
                        onDrop: { urls in onDrop(tile, urls) },
                        menu: { menu(tile, windowTitles(for: tile)) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var media: some View {
        if let playing = model.nowPlaying {
            MediaSegment(
                playing: playing,
                artwork: model.nowPlayingArtwork,
                size: iconSize * 0.78,
                onCommand: onMedia
            )
        }
    }

    /// The right-hand end: the bin, the volume, and the clock. Three things the system keeps in
    /// three different places, which is exactly why putting them together is worth doing.
    private var systemItems: some View {
        HStack(spacing: 12) {
            downloads
            agent
            trash
            volume
            clock
        }
    }

    /// A ring that fills while something is downloading, and is not there when nothing is.
    ///
    /// The queue already knows its own progress; this is that number, on the bar, where a glance
    /// finds it without opening anything.
    @ViewBuilder
    private var downloads: some View {
        if let progress = model.downloadProgress {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: iconSize * 0.34, weight: .semibold))
            }
            .frame(width: iconSize * 0.72, height: iconSize * 0.72)
            .motion(Motion.metric, value: progress)
            .help(String(localized: "Downloading", comment: "Bar segment"))
            .accessibilityLabel(String(localized: "Downloading", comment: "Bar segment"))
        }
    }

    @ViewBuilder
    private var agent: some View {
        if model.showsAgent {
            AnchoredButton(symbol: "sparkles", size: iconSize * 0.82, action: onAgent)
                .help(String(localized: "Assistant", comment: "Bar segment"))
                // Files can be handed to it directly. Two features that each cost something on
                // their own, and together cost nothing more: the dock already receives drags and
                // the assistant already knows what to do with a path.
                .dropDestination(for: URL.self) { urls, _ in
                    // Explicit, because an implicit-return closure here binds to the overload whose
                    // action returns nothing and the answer is silently thrown away.
                    return onDropOnAgent(urls)
                }
        }
    }

    @ViewBuilder
    private var trash: some View {
        if let tile = model.tiles.first(where: { if case .trash = $0.kind { true } else { false } }) {
            StripIcon(
                tile: tile, size: iconSize * 0.82, badge: nil, style: style, isFrontmost: false,
                onOpen: { frame in onOpenTile(tile, frame) }, onHover: { _ in },
                onDrop: { urls in onDrop(tile, urls) },
                menu: { menu(tile, []) }
            )
        }
    }

    private var volume: some View {
        AnchoredButton(symbol: "speaker.wave.2.fill", size: iconSize * 0.82, action: onVolume)
            .help(String(localized: "Sound", comment: "Bar segment"))
    }

    /// The strip at the very end, which is where Windows has put it for fifteen years.
    ///
    /// Deliberately not an icon among icons: it is a sliver at the edge of the screen, the one place
    /// a pointer can reach without aiming. Its width is the whole of its affordance, so it keeps the
    /// bar's full height and sits flush against the corner — which is also why the bar's trailing
    /// padding is zero.
    private var showDesktop: some View {
        ShowDesktopStrip(height: style.barHeight, isShowing: model.isDesktopShowing, action: onShowDesktop)
    }

    /// Time over date, which is how a strip this short fits both.
    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .trailing, spacing: -2) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }
}

// MARK: - Surface

/// What the strip is drawn on: dark glass, and one line of light.
///
/// The glass is the system's own blur under a dark tint thin enough that the wallpaper still comes
/// through. The line runs along the edge that faces the rest of the screen, and it is not
/// decoration — without it a dark strip flush against the bottom of a display reads as a gap in the
/// display rather than a surface on it. It carries a trace of the front application's colour, which
/// is the only place any colour of ours appears.
private struct DockSurface: View {
    let style: DockStyle
    let accent: Color

    /// The edge that faces the rest of the screen — the top of a bottom bar, the bottom of a top
    /// one. Everything here is anchored to it, because that is the edge anyone actually sees.
    private var inner: Alignment { style.edge == .bottom ? .top : .bottom }
    private var towardsInner: UnitPoint { style.edge == .bottom ? .top : .bottom }
    private var towardsEdge: UnitPoint { style.edge == .bottom ? .bottom : .top }

    var body: some View {
        ZStack {
            base

            // A breath of the front application's colour at the screen edge, gone well before the
            // other side. Enough that switching from Safari to Music is visible if you look; not
            // enough to be a thing on the screen in its own right.
            LinearGradient(
                colors: [accent.opacity(0.12), .clear],
                startPoint: towardsEdge,
                endPoint: towardsInner
            )
            .blendMode(.plusLighter)
        }
        .overlay(alignment: inner) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.07), accent.opacity(0.38), .white.opacity(0.07)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .compositingGroup()
        .motion(Motion.fluid, value: accent)
    }

    @ViewBuilder
    private var base: some View {
        switch style.surface {
        case .glass:
            Rectangle().fill(.ultraThinMaterial)
        case .solid:
            // Glass underneath a colour rather than the colour alone: the blur is what picks up the
            // wallpaper, and a fill over it still moves with the desktop instead of sitting there
            // as a painted block.
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill((style.tint ?? .black).opacity(style.backgroundOpacity))
        case .none:
            Color.clear
        }
    }
}

// MARK: - Playback

/// What is playing: its cover, its title, how far through it is, and the transport.
///
/// The progress line is the part worth pointing at. A track's name tells you what is on; a line
/// creeping across underneath tells you how much is left, and that is the thing people actually
/// glance down for.
private struct MediaSegment: View {
    let playing: NowPlaying
    let artwork: NSImage?
    let size: CGFloat
    var onCommand: (DockStripView.MediaCommand) -> Void

    private var isPlaying: Bool { playing.isPlaying ?? true }

    var body: some View {
        HStack(spacing: 9) {
            cover

            VStack(alignment: .leading, spacing: 1) {
                Text(playing.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let progress = playing.progress {
                    progressLine(progress)
                } else if !playing.artist.isEmpty {
                    Text(playing.artist)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 132, alignment: .leading)

            HStack(spacing: 11) {
                transport("backward.end.fill") { onCommand(.previous) }
                transport(isPlaying ? "pause.fill" : "play.fill") { onCommand(.playPause) }
                transport("forward.end.fill") { onCommand(.next) }
            }
        }
        .help(playing.artist.isEmpty ? playing.title : "\(playing.title) — \(playing.artist)")
    }

    /// The cover if the source handed one over, otherwise its own glyph. Either way the equaliser
    /// sits on top of it while sound is coming out, so playing and paused are two visibly different
    /// states rather than one swapped glyph.
    private var cover: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.primary.opacity(0.10))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.44))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if isPlaying { Equaliser().padding(2) }
        }
    }

    private func progressLine(_ progress: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.18))
                Capsule()
                    .fill(.primary.opacity(0.7))
                    .frame(width: max(2, proxy.size.width * progress))
            }
        }
        .frame(height: 2.5)
        .padding(.top, 2)
        .motion(Motion.metric, value: progress)
    }

    private func transport(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Three bars keeping time with nothing in particular.
///
/// Not driven by the audio — reading levels for something this small would cost more than it is
/// worth. It says one thing, honestly: sound is coming out. Still when Reduce Motion is on, because
/// a permanent animation is exactly what that setting exists to stop.
///
/// The bars keep a fixed height and are scaled, rather than having their height animated. That is
/// not a detail: an animated `frame(height:)` is an animated *layout*, so SwiftUI re-laid out the
/// entire strip — two dozen icons, the spacers, the clock — sixty times a second for three bars
/// four points tall. A sample of the app at rest was sixteen per cent of a core inside
/// `layoutSubtreeIfNeeded`. A scale is a transform: the layout is computed once and the render
/// server does the rest.
private struct Equaliser: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    /// Resting and peak heights as a fraction of the full height, with the period each bar keeps.
    private let bars: [(low: CGFloat, high: CGFloat, duration: Double)] = [
        (0.3, 0.9, 0.42),
        (0.6, 0.4, 0.53),
        (0.4, 0.8, 0.36)
    ]

    private static let height: CGFloat = 10

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: Self.height)
                    .scaleEffect(y: isAnimating ? bar.high : bar.low, anchor: .bottom)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: bar.duration).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .onAppear { isAnimating = true }
    }
}

// MARK: - Buttons

/// Makes a tile draggable when there is something to drag.
///
/// A modifier rather than an `if` around `.draggable`, because the two branches would otherwise be
/// different view types and SwiftUI would rebuild the icon — losing its hover state — whenever the
/// answer changed.
private struct DraggableTile: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.draggable(url)
        } else {
            content
        }
    }
}

/// The sliver at the end of the bar that clears the screen.
private struct ShowDesktopStrip: View {
    let height: CGFloat
    let isShowing: Bool
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(isShowing ? 0.22 : (isHovered ? 0.14 : 0.06)))
            .overlay(alignment: .leading) {
                // A hairline of its own, so the sliver reads as a control rather than as the bar
                // running out of content.
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 1)
            }
            .frame(width: 9, height: height)
            .contentShape(.rect)
            .onTapGesture(perform: action)
            .onHover { isHovered = $0 }
            .motion(Motion.snappy, value: isHovered)
            .motion(Motion.snappy, value: isShowing)
            .help(String(localized: "Show Desktop", comment: "Bar segment: clears the screen"))
            .accessibilityLabel(String(localized: "Show Desktop", comment: "Bar segment: clears the screen"))
            .accessibilityAddTraits(isShowing ? [.isButton, .isSelected] : .isButton)
    }
}

/// A button that reports where it is, so what it opens can appear beside it.
private struct AnchoredButton: View {
    let symbol: String
    let size: CGFloat
    var action: (CGRect) -> Void

    @State private var frameInWindow: CGRect = .zero
    @State private var isHovered = false

    var body: some View {
        Button {
            action(frameInWindow)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.6))
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: size, height: size)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Grows, like everything else here. Nothing in this bar lights a rectangle up behind
        // itself, and a speaker that did would be the only thing that does.
        .scaleEffect(isHovered ? 1.18 : 1)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .reportingFrame($frameInWindow)
    }
}

/// The first button in the bar, which opens the start menu.
///
/// The one saturated object on the strip, and deliberately: everything else here belongs to some
/// other application, and this is the app itself. A bar whose own button is indistinguishable from
/// the icons beside it is a bar nobody finds.
private struct StartButton: View {
    let size: CGFloat
    var action: (CGRect) -> Void

    @State private var frameInWindow: CGRect = .zero
    @State private var isHovered = false

    var body: some View {
        Button {
            action(frameInWindow)
        } label: {
            // The glyph the status item uses, so the button in the bar is recognisably the same app.
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background {
                    Circle().fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor,
                                Color.accentColor.mix(with: .black, by: 0.3)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .shadow(color: Color.accentColor.opacity(isHovered ? 0.6 : 0.35), radius: isHovered ? 8 : 5, y: 1)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.1 : 1)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .reportingFrame($frameInWindow)
        .help("MagicPlus")
    }
}

/// A running application in the strip, with the count the Dock is drawing on it.
///
/// Hovering grows the icon. That is the whole treatment — no panel appears behind it, because a
/// rounded grey rectangle under one icon in a bar that has no other rectangles in it is exactly what
/// made the previous version look cheap. Growing is also what the Dock has always done.
///
/// The growth is a scale, and scaling deliberately: it changes nothing about the layout, so no
/// amount of moving the pointer along the bar can ask the window to resize itself — which is what
/// froze the app the first time this bar was written.
private struct StripIcon: View {
    let tile: DockTile
    let size: CGFloat
    let badge: String?
    let style: DockStyle
    /// Marked differently from the rest: the app you are in is worth telling apart from the apps
    /// that merely happen to be open.
    let isFrontmost: Bool
    var onOpen: (CGRect) -> Void
    /// The icon's rectangle in window coordinates while the pointer is on it, `nil` when it leaves.
    var onHover: (CGRect?) -> Void
    var onDrop: ([URL]) -> Bool
    var menu: () -> DockTileMenu

    @State private var isHovered = false
    @State private var isDropTarget = false
    @State private var frameInWindow: CGRect = .zero

    private var accent: Color {
        DockAccent.color(for: DockIconCache.icon(for: tile, size: 32), key: tile.id) ?? .white
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: DockIconCache.icon(for: tile, size: size * 2))
                .resizable()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(isHovered && style.highlightsHovered ? 0.45 : 0), radius: 5, y: 2)
                .overlay {
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .shadow(color: Color.accentColor.opacity(0.8), radius: 5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 0.5)
                            .background {
                                Capsule().fill(.red).shadow(color: .red.opacity(0.6), radius: 3)
                            }
                            .offset(x: 6, y: -3)
                    }
                }

            indicator
        }
        // A drop target grows too, and a little further, because a drag needs to say plainly which
        // icon is going to catch it.
        .scaleEffect(isDropTarget ? 1.3 : (isHovered && style.highlightsHovered ? 1.22 : 1))
        .reportingFrame($frameInWindow)
        // Dragging an icon carries the application itself, which is what lets the drop handler tell
        // a reorder from a document without keeping any state about where the drag began.
        .modifier(DraggableTile(url: tile.isApplication ? tile.url : nil))
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
        } isTargeted: { isDropTarget = $0 }
        .motion(Motion.snappy, value: isDropTarget)
        .onHover { hovering in
            isHovered = hovering
            onHover(hovering ? frameInWindow : nil)
        }
        .motion(Motion.snappy, value: isHovered)
        .contentShape(.rect)
        .onTapGesture { onOpen(frameInWindow) }
        .help(tile.name)
        .accessibilityLabel(badge == nil ? tile.name : "\(tile.name), \(badge ?? "")")
        .accessibilityAddTraits(isFrontmost ? [.isButton, .isSelected] : .isButton)
        .contextMenu { menu() }
    }

    /// A dot for a running app, and a wider one, in that app's own colour, for the app in front.
    @ViewBuilder
    private var indicator: some View {
        if tile.isRunning, style.indicator != .none {
            Capsule()
                .fill(isFrontmost ? AnyShapeStyle(accent) : AnyShapeStyle(.primary.opacity(0.4)))
                .frame(width: indicatorWidth, height: 3.5)
                .shadow(color: isFrontmost ? accent.opacity(0.75) : .clear, radius: 3)
                .motion(Motion.fluid, value: isFrontmost)
        } else {
            // Sized in both directions on purpose. A `Color` with only its height fixed is
            // infinitely wide, and this one once stretched the entire right-hand end of the bar
            // across the screen — the bin ended up in the middle of it.
            Color.clear.frame(width: 3.5, height: 3.5)
        }
    }

    private var indicatorWidth: CGFloat {
        switch style.indicator {
        case .bar: size
        case .dot, .none: isFrontmost ? 13 : 3.5
        }
    }
}

private extension View {
    /// Keeps a binding up to date with where this view is in the window, so a panel can be opened
    /// against it. Three views here needed the same fifteen lines of `GeometryReader`.
    func reportingFrame(_ frame: Binding<CGRect>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { frame.wrappedValue = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, new in frame.wrappedValue = new }
            }
        }
    }
}
