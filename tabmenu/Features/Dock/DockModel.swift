//
//  DockModel.swift
//  MagicPlus
//

import AppKit
import CoreGraphics
import Observation

/// What the dock is showing.
///
/// Exists so the view can be built once and then follow this, rather than being replaced whenever
/// something changes. That distinction is not tidiness: assigning a new `rootView` to an
/// `NSHostingView` — or moving its window — while AppKit is in the middle of a display cycle throws
/// an uncaught exception and takes the app with it. Which is exactly what a hover handler does,
/// several times a second.
@Observable
@MainActor
final class DockModel {
    var tiles: [DockTile] = []
    var style = DockStyle()
    /// The window's size, decided by the controller — the only place with a screen to measure
    /// against. The view reads it rather than working it out again, because the two answers have to
    /// be the same and once were not.
    var windowSize: CGSize = .zero
    /// The windows open right now, read once per tick. Used for the titles in an icon's menu and
    /// for keeping windows out of the strip — one list, because two sweeps of the Accessibility
    /// tree for the same answer is one too many.
    var windows: [SwitchableWindow] = []
    /// The application in front and the title of its front window, for the bar layout — which is
    /// the segment that makes a bar a bar rather than a row of icons.
    var frontmostName: String = ""
    var frontmostIcon: NSImage?
    var frontmostWindowTitle: String = ""
    /// Which app that is, so a tile can be marked as the one in front and the strip can take its
    /// colour. Names are what people read; identifiers are what the bar should compare.
    var frontmostBundleIdentifier: String = ""
    /// What is playing, if anything.
    var nowPlaying: NowPlaying?
    /// Its cover, once it has been fetched. Optional in every sense: the strip draws the source's
    /// own glyph until this arrives, and for a source that has no artwork it never does.
    var nowPlayingArtwork: NSImage?
    /// Notification counts the Dock is drawing, by bundle identifier.
    var badges: [String: String] = [:]
    /// Whether the assistant button belongs on the bar. Here rather than read straight from
    /// preferences by the view builder, because the root view is built once and then follows this
    /// model — a value captured at build time would not change until the app was relaunched.
    var showsAgent = false
    /// How far along the download queue is, or `nil` when nothing is downloading.
    var downloadProgress: Double?
    /// Whether the strip is currently parked off the edge. Only meaningful when it auto-hides.
    var isAutoHidden = false
    /// Whether the screen is currently cleared by the sliver at the end of the bar.
    var isDesktopShowing = false
}
