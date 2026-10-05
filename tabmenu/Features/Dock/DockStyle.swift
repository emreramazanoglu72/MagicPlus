//
//  DockStyle.swift
//  MagicPlus
//

import SwiftUI

/// How the app's own bar looks.
///
/// One value rather than a dozen loose preferences, and `Codable`, so a field added later reads as
/// its default out of old stored JSON instead of needing a migration.
///
/// It used to carry eight named themes — macOS, two Windows, Ubuntu and so on — and they are gone,
/// and after them the two other shapes the dock could take: a row of magnifying icons and a sidebar
/// listing windows. Neither could be reached from anywhere in the app, so both were a picker's worth
/// of fields and five hundred lines of view describing something nobody could see. The app draws one
/// thing: a strip along the edge. Its defaults *are* what that strip looks like, so there is no
/// separate idea of "the default look" that could disagree with them.
nonisolated struct DockStyle: Codable, Equatable, Sendable {
    /// Which edge it sits on.
    ///
    /// Two, not four. The bar is a horizontal strip — a window title, a track name and a clock read
    /// left to right — and standing that on its end does not produce a vertical dock, it produces a
    /// horizontal strip drawn inside a tall window with nothing beside it. Offering a position that
    /// cannot work is worse than not offering it, so left and right are gone and the top, which
    /// does work, is here instead. A style stored with the old values reads as `bottom`.
    enum Edge: String, Codable, CaseIterable, Identifiable, Sendable {
        case bottom, top

        var id: String { rawValue }

        /// Kept for the geometry that still asks. Nothing the app draws is vertical any more.
        var isVertical: Bool { false }

        var title: String {
            switch self {
            case .bottom: String(localized: "Bottom", comment: "Bar edge")
            case .top: String(localized: "Top", comment: "Bar edge")
            }
        }
    }

    /// The surface behind the icons.
    enum Surface: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The system's own blur, which picks up the wallpaper the way the real Dock does.
        case glass
        /// A flat fill at the chosen colour and opacity, for a look the system does not offer.
        case solid
        /// Nothing at all: icons floating on the wallpaper.
        case none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .glass: String(localized: "Glass", comment: "Dock surface")
            case .solid: String(localized: "Solid colour", comment: "Dock surface")
            case .none: String(localized: "None", comment: "Dock surface")
            }
        }
    }

    /// How a running app is marked. The difference between a dock and a taskbar is largely this.
    enum Indicator: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A dot under the icon, the way macOS does it.
        case dot
        /// A short bar along the edge, the way Windows does it.
        case bar
        case none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dot: String(localized: "Dot", comment: "Dock running indicator")
            case .bar: String(localized: "Bar", comment: "Dock running indicator")
            case .none: String(localized: "None", comment: "Dock running indicator")
            }
        }
    }

    /// Where the icons sit when the dock spans the whole edge.
    enum Alignment: String, Codable, CaseIterable, Identifiable, Sendable {
        case center
        case leading
        case trailing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .center: String(localized: "Centred", comment: "Dock alignment")
            case .leading: String(localized: "From the start", comment: "Dock alignment")
            case .trailing: String(localized: "From the end", comment: "Dock alignment")
            }
        }
    }

    /// Which generation of the look this was saved under.
    ///
    /// Without it a redesign reaches nobody. Everyone who has already run the app has a stored
    /// style with every old value written into it, so new defaults would apply to new installs
    /// only and every existing user would keep the old bar for ever. Bumping this takes the
    /// fields that describe how the strip is *drawn* fresh, once, and leaves the fields the user
    /// actually chose alone.
    static let appearanceVersion = 3
    var appearanceVersion: Int = DockStyle.appearanceVersion

    var edge: Edge = .bottom
    var surface: Surface = .solid
    /// Hex without the hash. Empty means "no tint", which leaves the glass as the system draws it.
    var tintHex: String = "0C0C12"
    /// Dark enough to be the same strip over any wallpaper, thin enough that the blur underneath
    /// still shows what is behind it. A near-opaque fill turns the bar into a black band, which is
    /// the one thing a glass surface must not look like.
    var backgroundOpacity: Double = 0.62
    /// Big enough to be an icon rather than a glyph. The strip draws no panels and no dividers, so
    /// the icons are most of what is on it, and at 24pt they read as a toolbar rather than a dock.
    var iconSize: Double = 32
    /// Space is what separates one group from the next here, since nothing is drawn between them.
    var spacing: Double = 14
    var showsRunningApps: Bool = true
    /// Distance from the screen edge. Zero sits flush against it.
    var edgeMargin: Double = 0

    /// Spans the whole screen edge rather than hugging its icons.
    var fillsEdge: Bool = true
    /// Centred. A bar that spans the whole screen with its icons crowded into the left-hand corner
    /// is mostly empty bar, and the emptiness is the first thing anyone sees.
    var alignment: Alignment = .center
    var indicator: Indicator = .dot
    /// Whether the icon under the pointer grows. It used to put a rounded panel behind it instead,
    /// which in a bar with nothing else drawn on it was the one cheap-looking thing on the screen.
    var highlightsHovered: Bool = true
    /// Whether the strip parks itself off the edge until the pointer reaches for it.
    ///
    /// Off by default: a dock that is not there is a dock somebody has to remember exists, and that
    /// is a choice rather than a default.
    var autoHides: Bool = false

    /// How much of a parked strip stays on screen. Enough to be reachable by shoving the pointer at
    /// the edge, little enough not to be a stripe across the display.
    nonisolated static let revealStrip: Double = 3

    /// Whether windows this app places should keep out of the dock's strip. Only meaningful for a
    /// dock that fills its edge — a floating pill is something windows can sit behind.
    var reservesSpace: Bool = true

    // MARK: - Decoding

    /// Written by hand, and it has to be.
    ///
    /// Swift's synthesised `Codable` requires every non-optional property to be present in the
    /// JSON, default value or not — so the moment a field is added here, everything stored by an
    /// older build fails to decode and the reader falls back to a fresh value. The user's whole
    /// dock would silently revert to the default look on an update. Field by field, missing means
    /// default, which is what makes the value safe to extend.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DockStyle()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }

        appearanceVersion = value(.appearanceVersion, 1)
        edge = value(.edge, fallback.edge)
        surface = value(.surface, fallback.surface)
        tintHex = value(.tintHex, fallback.tintHex)
        backgroundOpacity = value(.backgroundOpacity, fallback.backgroundOpacity)
        iconSize = value(.iconSize, fallback.iconSize)
        spacing = value(.spacing, fallback.spacing)
        showsRunningApps = value(.showsRunningApps, fallback.showsRunningApps)
        fillsEdge = value(.fillsEdge, fallback.fillsEdge)
        alignment = value(.alignment, fallback.alignment)
        indicator = value(.indicator, fallback.indicator)
        highlightsHovered = value(.highlightsHovered, fallback.highlightsHovered)
        reservesSpace = value(.reservesSpace, fallback.reservesSpace)
        autoHides = value(.autoHides, fallback.autoHides)
        edgeMargin = value(.edgeMargin, fallback.edgeMargin)

        // Where the bar sits, how big its icons are and whether it holds screen space back are
        // decisions somebody made; how it is painted is ours, and a new look has to be allowed to
        // replace an old one. Idempotent — running it against an already-migrated style changes
        // nothing.
        if appearanceVersion < DockStyle.appearanceVersion {
            surface = fallback.surface
            tintHex = fallback.tintHex
            backgroundOpacity = fallback.backgroundOpacity
            spacing = fallback.spacing
            indicator = fallback.indicator
            highlightsHovered = fallback.highlightsHovered
            alignment = fallback.alignment
            appearanceVersion = DockStyle.appearanceVersion
        }
    }

    /// The memberwise initialiser, which writing `init(from:)` otherwise takes away.
    init(
        appearanceVersion: Int = DockStyle.appearanceVersion,
        edge: Edge = .bottom,
        surface: Surface = .solid,
        tintHex: String = "0C0C12",
        backgroundOpacity: Double = 0.62,
        iconSize: Double = 32,
        spacing: Double = 14,
        showsRunningApps: Bool = true,
        edgeMargin: Double = 0,
        fillsEdge: Bool = true,
        alignment: Alignment = .center,
        indicator: Indicator = .dot,
        highlightsHovered: Bool = true,
        reservesSpace: Bool = true,
        autoHides: Bool = false
    ) {
        self.appearanceVersion = appearanceVersion
        self.edge = edge
        self.surface = surface
        self.tintHex = tintHex
        self.backgroundOpacity = backgroundOpacity
        self.iconSize = iconSize
        self.spacing = spacing
        self.showsRunningApps = showsRunningApps
        self.edgeMargin = edgeMargin
        self.fillsEdge = fillsEdge
        self.alignment = alignment
        self.indicator = indicator
        self.highlightsHovered = highlightsHovered
        self.reservesSpace = reservesSpace
        self.autoHides = autoHides
    }

    // MARK: - Derived

    /// `@MainActor` because building a `Color` from hex is: the value itself is plain data, but the
    /// colour it turns into belongs to the interface that draws it.
    @MainActor
    var tint: Color? {
        guard !tintHex.isEmpty else { return nil }
        return Color(hex: tintHex)
    }

    var showsRunningIndicators: Bool { indicator != .none }

    /// Relative luminance of the tint, 0 to 1. Plain arithmetic on the stored hex, so it stays
    /// where the rest of the value is rather than needing AppKit to answer it.
    var tintLuminance: Double? {
        var value = tintHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        let red = Double((number & 0xFF0000) >> 16) / 255
        let green = Double((number & 0x00FF00) >> 8) / 255
        let blue = Double(number & 0x0000FF) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// The appearance the strip's contents should be drawn in, or `nil` to follow the system.
    ///
    /// A bar that paints its own background decides its own appearance. Letting the contents follow
    /// the desktop instead means that in Light Mode a dark strip gets dark grey labels on dark grey
    /// glass and dark dots under the icons — legible to nobody. What settles it is the colour the
    /// bar is actually painted, which is known right here.
    ///
    /// Only for a surface solid enough to be that colour: glass thin enough to show the wallpaper
    /// through is whatever the wallpaper is, and the system's own answer is the better one.
    var contentScheme: ColorScheme? {
        guard surface == .solid, backgroundOpacity >= 0.45, let tintLuminance else { return nil }
        return tintLuminance < 0.4 ? .dark : .light
    }

    /// The icons the strip draws at. A bar is short: past this an icon stops being an icon in a bar
    /// and starts being a dock that happens to have a clock in it.
    var barIconSize: Double { min(iconSize, 34) }

    /// How tall the strip is.
    ///
    /// Here, and only here. The window's height and the view's height have to be the same number,
    /// and when each worked it out for itself they stopped being the same number and the dock ran
    /// off the edge of the screen. Both read this.
    var barHeight: Double { barIconSize + 20 }


}
