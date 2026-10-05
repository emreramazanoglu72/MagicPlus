//
//  DockLayout.swift
//  MagicPlus
//

import AppKit
import SwiftUI

/// Where the strip's parts are, in numbers.
///
/// Kept apart from both the view and the window so the same arithmetic answers "how big must the
/// window be" and "how big can the icons be" — two questions that have to agree, and once were
/// worked out twice.
nonisolated struct DockLayout {
    let tileCount: Int

    /// Gaps never close entirely: icons touching each other are one icon.
    static let minimumSpacing: Double = 6

    static func padding(for style: DockStyle) -> CGFloat {
        style.surface == .none ? 0 : max(6, style.iconSize * 0.18)
    }

    /// How long the row of icons is.
    func iconExtent(for style: DockStyle) -> CGFloat {
        CGFloat(tileCount) * style.iconSize + CGFloat(max(0, tileCount - 1)) * style.spacing
    }

    /// The space the icons need, end to end, with their padding.
    func windowSize(for style: DockStyle) -> CGSize {
        let along = iconExtent(for: style) + Self.padding(for: style) * 2
        let across = style.iconSize
            + (style.showsRunningIndicators ? 7 : 0)
            + Self.padding(for: style) * 2
        return CGSize(width: along, height: across)
    }

    /// The same style, shrunk to whatever actually fits.
    ///
    /// A dock wider than the screen is not a dock: half of it is off the edge and the rest is in
    /// the wrong place. macOS's own Dock shrinks its tiles when it gets crowded, and so does this.
    ///
    /// Measured with `windowSize` rather than solved on paper, and deliberately: asking the same
    /// function that sizes the strip cannot disagree with it.
    func clamped(_ style: DockStyle, toLength available: CGFloat) -> DockStyle {
        guard tileCount > 0, available > 0 else { return style }
        guard windowSize(for: style).width > available else { return style }

        var candidate = style

        // The gaps go first, and it has to be that way round. Icons are what a dock is for; the
        // space between them is not. A point off every gap and a point off every icon cost about
        // the same room, but one of them is invisible and the other is the thing being looked at —
        // and a crowded dock that shrank its icons first came out at twenty-three points when the
        // gaps still had eight points of slack in them.
        while candidate.spacing > Self.minimumSpacing {
            candidate.spacing -= 1
            if windowSize(for: candidate).width <= available { return candidate }
        }

        var size = candidate.iconSize.rounded(.down)
        while size > 16 {
            size -= 1
            candidate.iconSize = size
            if windowSize(for: candidate).width <= available { break }
        }
        return candidate
    }
}

/// Icons, kept once read. `NSWorkspace.icon(forFile:)` goes to disk, and the strip asks for every
/// one of them on every pass it makes.
@MainActor
enum DockIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for tile: DockTile, size: CGFloat) -> NSImage {
        let key = "\(tile.id)|\(Int(size))"
        if let cached = cache[key] { return cached }

        let image: NSImage = {
            if case .trash = tile.kind {
                return NSImage(named: NSImage.trashFullName) ?? NSImage()
            }
            guard let url = tile.url else { return NSImage() }
            return NSWorkspace.shared.icon(forFile: url.path)
        }()
        image.size = NSSize(width: size, height: size)

        // Bounded: a dock is a couple of dozen tiles, and a cache that grows without limit is a
        // leak with a friendly name.
        if cache.count > 120 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
