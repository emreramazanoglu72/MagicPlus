//
//  NotchDesign.swift
//  tabmenu
//

import SwiftUI

/// The island's design tokens and the controls built from them.
///
/// Everything drawn inside the island comes from here. The island is the one surface in the
/// app that cannot borrow the system's materials — it has to pass for hardware, on pure black,
/// at small sizes — so it carries its own scale of type, spacing, fills and radii rather than
/// improvising a value per view. Three text weights, four fills, five radii: if a value is
/// not in this file, it does not belong in the island.
enum Island {
    /// Everything sits on a 4pt grid.
    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// Concentric: an inset child uses the parent's radius minus the padding between them,
    /// which is what keeps nested corners looking parallel instead of merely rounded.
    enum Radius {
        static let control: CGFloat = 8
        static let tile: CGFloat = 12
        static let card: CGFloat = 14
        static let panel: CGFloat = 26
    }

    /// Text on black. Three steps, no more: headline, supporting, and the quiet stuff.
    enum Ink {
        static let primary = Color.white
        static let secondary = Color.white.opacity(0.62)
        static let tertiary = Color.white.opacity(0.38)
        /// For text sitting on a white fill.
        static let inverted = Color.black
    }

    /// Surfaces on black, each a deliberate step apart so hover reads as a change rather
    /// than a shimmer.
    enum Fill {
        static let subtle = Color.white.opacity(0.06)
        static let regular = Color.white.opacity(0.10)
        static let strong = Color.white.opacity(0.16)
        static let hover = Color.white.opacity(0.22)
        static let solid = Color.white
    }

    static let hairline = Color.white.opacity(0.09)

    /// Meaning, not decoration. Slightly lifted off the pure system hues, which vibrate
    /// against an OLED black and read as cheap at these sizes.
    enum Signal {
        static let info = Color(red: 0.42, green: 0.66, blue: 1.00)
        static let success = Color(red: 0.36, green: 0.83, blue: 0.51)
        static let warning = Color(red: 1.00, green: 0.74, blue: 0.31)
        static let danger = Color(red: 1.00, green: 0.45, blue: 0.42)
        static let media = Color(red: 0.68, green: 0.60, blue: 1.00)
    }

    /// Four sizes and three weights, and numbers always tabular so a changing value never
    /// shifts the layout around it.
    enum Text {
        static let title = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 12, weight: .regular)
        static let label = Font.system(size: 11, weight: .medium)
        static let caption = Font.system(size: 10, weight: .regular)
        static let numeric = Font.system(size: 11, weight: .medium).monospacedDigit()
        static let numericSmall = Font.system(size: 10, weight: .regular).monospacedDigit()
    }

    /// Height every pane occupies, whatever it holds. A panel that resizes as the user moves
    /// between tabs reads as unfinished, and it moves the tab the pointer is aiming at.
    static let paneHeight: CGFloat = 186
}

// MARK: - Surface

/// The island's body.
///
/// The strip level with the notch stays pure black so the silhouette passes for the hardware;
/// below it the surface lifts very slightly and picks up a hairline edge, which is what stops
/// the open panel reading as a black rectangle pasted over the wallpaper.
struct IslandSurface: View {
    let shape: NotchShape
    let isExpanded: Bool
    /// Height of the strip that has to stay indistinguishable from the hardware.
    let stripHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let blend = proxy.size.height > 0 ? min(1, stripHeight / proxy.size.height) : 1

            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: blend),
                            .init(color: Color(white: isExpanded ? 0.08 : 0.03), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    if isExpanded {
                        shape.stroke(Island.hairline, lineWidth: 1)
                    }
                }
        }
        .shadow(
            color: .black.opacity(isExpanded ? 0.55 : 0.3),
            radius: isExpanded ? 28 : 10,
            y: isExpanded ? 12 : 5
        )
    }
}

// MARK: - Controls

/// Round icon button. The primary variant is a filled white disc — on black there is no
/// stronger emphasis available, and playback needs exactly one.
struct IslandIconButton: View {
    let systemImage: String
    let help: String
    var isPrimary = false
    var size: CGFloat = 28
    let action: () -> Void

    @State private var isHovered = false

    private var diameter: CGFloat { isPrimary ? size + 8 : size }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 13 : 11, weight: .semibold))
                .foregroundStyle(isPrimary ? Island.Ink.inverted : Island.Ink.primary.opacity(isHovered ? 1 : 0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .background(background, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }

    private var background: Color {
        if isPrimary { return isHovered ? Island.Fill.solid : Island.Fill.solid.opacity(0.92) }
        return isHovered ? Island.Fill.strong : Island.Fill.regular
    }
}

/// Text button for the secondary actions inside panes — Join, Allow, and friends.
struct IslandChipButton: View {
    let title: LocalizedStringKey
    var isProminent = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Island.Text.label)
                .foregroundStyle(isProminent ? Island.Ink.inverted : Island.Ink.primary)
                .padding(.horizontal, Island.Space.m)
                .padding(.vertical, 5)
                .background(background, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
    }

    private var background: Color {
        if isProminent { return isHovered ? Island.Fill.solid : Island.Fill.solid.opacity(0.9) }
        return isHovered ? Island.Fill.hover : Island.Fill.strong
    }
}

/// Read-only status chip: a glyph and a value, for the quiet corner of the header.
struct IslandStatusChip: View {
    let systemImage: String
    let value: String
    var tint: Color = Island.Ink.secondary

    var body: some View {
        HStack(spacing: Island.Space.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(value)
                .font(Island.Text.numeric)
                .contentTransition(.numericText())
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}

/// Filled capsule used for volume, playback position and any other 0...1 value.
struct LevelBar: View {
    let value: Double
    var tint: Color = Island.Ink.primary
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Island.Fill.strong)
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, proxy.size.width * value.clampedToUnitRange))
            }
        }
        .frame(height: height)
        .motion(Motion.snappy, value: value)
    }
}

/// Ring showing how far along something is, for the resting island where there is room for a
/// mark but not for a bar.
///
/// With no total to go on it draws a short fixed arc rather than animating: a spinner on the
/// menu bar strip is movement in the corner of the eye all day, and a full circle would claim
/// a progress nobody knows.
struct IslandProgressRing: View {
    let value: Double?
    var tint: Color = Island.Signal.info
    var diameter: CGFloat = 14
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Island.Fill.strong, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: value?.clampedToUnitRange ?? 0.15)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .motion(Motion.snappy, value: value ?? 0)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Download progress")
        .accessibilityValue(value.map(Format.percent) ?? String(localized: "In progress", comment: "Download with no known size"))
    }
}

/// The same bar, draggable. The system slider looks foreign on this surface, and its hit
/// area is larger than the bar it draws so a 4pt line is still easy to grab.
struct IslandSlider: View {
    let value: Double
    var tint: Color = Island.Ink.primary
    let onChange: (Double) -> Void

    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Island.Fill.strong)
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, proxy.size.width * value.clampedToUnitRange))
            }
            .frame(height: isHovered ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onChange((gesture.location.x / proxy.size.width).clampedToUnitRange)
                    }
            )
        }
        .frame(height: 16)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
    }
}

/// Album art, or a placeholder that does not pretend to be album art.
struct ArtworkTile: View {
    let image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Island.Fill.regular)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4, weight: .medium))
                            .foregroundStyle(Island.Ink.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Island.hairline, lineWidth: 1)
        }
    }
}

// MARK: - Layout

/// Fixed-height home for a pane, so the panel never resizes underneath the pointer.
struct IslandPane<Content: View>: View {
    var scrolls = false
    var alignment: Alignment = .topLeading
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if scrolls {
                ScrollView(.vertical) {
                    // A scroll view proposes an unbounded height, which collapses anything
                    // that asks to fill it — an empty state, typically. The minimum gives
                    // such content the pane to centre itself in, and longer content still
                    // scrolls past it.
                    content.frame(maxWidth: .infinity, minHeight: Island.paneHeight, alignment: .top)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                content
            }
        }
        .frame(height: Island.paneHeight, alignment: alignment)
    }
}

/// One way of saying "there is nothing here", used by every pane that can be empty.
struct IslandEmptyState<Action: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Island.Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Island.Ink.tertiary)
            VStack(spacing: Island.Space.xs) {
                Text(title)
                    .font(Island.Text.body)
                    .foregroundStyle(Island.Ink.secondary)
                if let message {
                    Text(message)
                        .font(Island.Text.caption)
                        .foregroundStyle(Island.Ink.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        // Long lines are hard to read centred; this is about 8 words a line.
                        .frame(maxWidth: 280)
                }
            }
            action
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

extension IslandEmptyState where Action == EmptyView {
    init(systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// The pane switcher: equal segments and one indicator that slides between them, rather than
/// pills that resize as the selection moves.
struct IslandTabRail: View {
    @Binding var selection: NotchTab
    /// Which panes to offer. Passed in rather than read from the enum, because a module that is
    /// switched off has no pane.
    let tabs: [NotchTab]
    let trailing: AnyView?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: Island.Space.s) {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    segment(tab)
                }
            }
            .padding(3)
            .background(Island.Fill.subtle, in: .capsule)

            if let trailing {
                trailing
            }
        }
    }

    private func segment(_ tab: NotchTab) -> some View {
        let isSelected = selection == tab

        return Button {
            withMotion(Motion.fluid, reduceMotion: reduceMotion) { selection = tab }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .symbolEffect(.bounce, value: isSelected)
                Text(tab.title)
                    .font(Island.Text.label)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Island.Ink.primary : Island.Ink.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Island.Fill.strong)
                        .matchedGeometryEffect(id: "islandTab", in: indicator)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
