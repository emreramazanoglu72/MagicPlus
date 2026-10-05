//
//  NotchActivityViews.swift
//  tabmenu
//

import SwiftUI

/// What an activity looks like, in one shape shared by all of them.
///
/// Thirteen bespoke layouts read as thirteen different apps taking turns in the same island.
/// Every activity now fills the same slots — a glyph on the left of the notch, a headline and
/// a detail line on the right, and at most one accessory — so the eye lands in the same place
/// whatever just happened, and only the content changes.
struct ActivityPresentation {
    enum Glyph {
        case symbol(String)
        case artwork
        case screenshot(URL)
    }

    var glyph: Glyph
    var tint: Color
    var title: String
    var detail: String?
    /// A 0...1 bar shown to the left of the text, for values rather than events.
    var meter: Double?
    /// A pill shown to the right of the text, for the activities you can act on.
    var badge: String?
    var showsWaveform: Bool
    /// Warnings colour their headline; everything else keeps a white headline so the tint
    /// stays in the glyph where it belongs.
    var isAlert: Bool

    init(
        glyph: Glyph,
        tint: Color = Island.Ink.primary,
        title: String,
        detail: String? = nil,
        meter: Double? = nil,
        badge: String? = nil,
        showsWaveform: Bool = false,
        isAlert: Bool = false
    ) {
        self.glyph = glyph
        self.tint = tint
        self.title = title
        self.detail = detail
        self.meter = meter
        self.badge = badge
        self.showsWaveform = showsWaveform
        self.isAlert = isAlert
    }
}

extension NotchActivity {
    var presentation: ActivityPresentation {
        switch self {
        case .nowPlaying(let info):
            ActivityPresentation(
                glyph: .artwork,
                tint: Island.Signal.media,
                title: info.title,
                detail: info.artist,
                showsWaveform: true
            )

        case .volume(let level):
            ActivityPresentation(
                glyph: .symbol(Self.volumeSymbol(for: level)),
                title: Format.percent(level),
                meter: level
            )

        case .meeting(let event):
            ActivityPresentation(
                glyph: .symbol("calendar"),
                tint: event.calendarColor,
                title: event.title,
                detail: event.countdownLabel(),
                badge: event.meetingURL == nil ? nil : String(localized: "Join", comment: "Open the meeting link")
            )

        case .filesAdded(let count):
            ActivityPresentation(
                glyph: .symbol("tray.and.arrow.down.fill"),
                tint: Island.Signal.info,
                title: String(localized: "\(count) files", comment: "Files added to the shelf"),
                detail: String(localized: "Added to shelf", comment: "Where the files went")
            )

        case .screenshot(let url):
            ActivityPresentation(
                glyph: .screenshot(url),
                tint: Island.Signal.media,
                title: String(localized: "Screenshot", comment: "Notch activity"),
                detail: String(localized: "Added to shelf", comment: "Where the files went")
            )

        case .download(let name):
            ActivityPresentation(
                glyph: .symbol("arrow.down.circle.fill"),
                tint: Island.Signal.success,
                title: name,
                detail: String(localized: "Downloaded", comment: "Notch activity")
            )

        case .downloadStarted(let name):
            ActivityPresentation(
                glyph: .symbol("arrow.down.circle"),
                tint: Island.Signal.info,
                title: name,
                detail: String(localized: "Downloading", comment: "Notch activity")
            )

        case .downloadFailed(let name):
            ActivityPresentation(
                glyph: .symbol("exclamationmark.triangle.fill"),
                tint: Island.Signal.danger,
                title: name,
                detail: String(localized: "Download failed", comment: "Notch activity"),
                isAlert: true
            )

        case .micStatus(let muted):
            ActivityPresentation(
                glyph: .symbol(muted ? "mic.slash.fill" : "mic.fill"),
                tint: muted ? Island.Signal.danger : Island.Signal.warning,
                title: muted
                    ? String(localized: "Mic muted", comment: "Notch activity")
                    : String(localized: "Mic live", comment: "Notch activity"),
                isAlert: muted
            )

        case .textCaptured(let characters):
            ActivityPresentation(
                glyph: .symbol("text.viewfinder"),
                tint: Island.Signal.media,
                title: String(localized: "\(characters) characters", comment: "Length of captured text"),
                detail: String(localized: "Copied as text", comment: "Notch activity")
            )

        case .lowBattery(let percentage):
            ActivityPresentation(
                glyph: .symbol("battery.25"),
                tint: Island.Signal.danger,
                title: Format.percent(Double(percentage) / 100),
                detail: String(localized: "Low battery", comment: "Notch activity"),
                isAlert: true
            )

        case .diskFull(let freeBytes):
            ActivityPresentation(
                glyph: .symbol("externaldrive.fill.badge.exclamationmark"),
                tint: Island.Signal.warning,
                title: Format.bytes(freeBytes),
                detail: String(localized: "Disk almost full", comment: "Notch activity"),
                isAlert: true
            )

        case .windowsRescued(let count):
            ActivityPresentation(
                glyph: .symbol("macwindow.and.cursorarrow"),
                tint: Island.Signal.info,
                title: String(localized: "\(count) windows", comment: "Windows pulled back on screen"),
                detail: String(localized: "Back on screen", comment: "Notch activity")
            )

        case .sleepDespiteKeepAwake:
            ActivityPresentation(
                glyph: .symbol("cup.and.saucer.fill"),
                tint: Island.Signal.warning,
                title: String(localized: "Mac slept despite Keep Awake", comment: "Notch activity"),
                detail: String(localized: "Lid closed or forced sleep", comment: "Why the Mac slept"),
                isAlert: true
            )

        case .power(let isCharging, let percentage):
            ActivityPresentation(
                glyph: .symbol(isCharging ? "bolt.fill" : "powerplug.fill"),
                tint: isCharging ? Island.Signal.success : Island.Signal.warning,
                title: Format.percent(Double(percentage) / 100),
                detail: isCharging
                    ? String(localized: "Charging", comment: "Notch activity")
                    : String(localized: "On battery", comment: "Notch activity")
            )
        }
    }

    private static func volumeSymbol(for level: Double) -> String {
        switch level {
        case ..<0.001: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// Left of the notch during an activity: one glyph, always in the same place and at the same
/// size, so a glance lands on it without hunting.
struct ActivityLeadingView: View {
    let activity: NotchActivity
    let model: NotchModel
    let morph: Namespace.ID

    private var presentation: ActivityPresentation { activity.presentation }

    var body: some View {
        HStack(spacing: Island.Space.s) {
            glyph
                .frame(width: 24, height: 20)

            if presentation.showsWaveform {
                Waveform(isPlaying: model.isPlaying, tint: presentation.tint, height: 12)
            }

            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch presentation.glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(presentation.tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: activity)

        case .artwork:
            ArtworkTile(image: model.artwork, size: 20, cornerRadius: 6)
                .matchedGeometryEffect(id: "artwork", in: morph)

        case .screenshot(let url):
            ScreenshotThumbnail(url: url)
        }
    }
}

/// Right of the notch: the words that explain the glyph, in the same two lines every time.
struct ActivityTrailingView: View {
    let activity: NotchActivity
    let model: NotchModel

    private var presentation: ActivityPresentation { activity.presentation }

    var body: some View {
        HStack(spacing: Island.Space.s) {
            Spacer(minLength: 0)

            if let meter = presentation.meter {
                LevelBar(value: meter, tint: presentation.tint, height: 4)
                    .frame(width: 36)
            }

            VStack(alignment: .trailing, spacing: 0) {
                Text(presentation.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(presentation.isAlert ? presentation.tint : Island.Ink.primary)
                    .contentTransition(.numericText())

                if let detail = presentation.detail {
                    Text(detail)
                        .font(Island.Text.caption)
                        .foregroundStyle(Island.Ink.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)

            if let badge = presentation.badge {
                // The whole capsule is the click target; this is only the affordance.
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Island.Ink.inverted)
                    .padding(.horizontal, Island.Space.s)
                    .padding(.vertical, 2)
                    .background(Island.Fill.solid, in: .capsule)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.detail.map { "\(presentation.title), \($0)" } ?? presentation.title)
    }
}

/// Left of the notch while the panel is open: what is playing, quietly.
struct ExpandedLeadingView: View {
    let model: NotchModel
    let morph: Namespace.ID

    var body: some View {
        HStack(spacing: Island.Space.s) {
            ArtworkTile(image: model.artwork, size: 20, cornerRadius: 6)
                .matchedGeometryEffect(id: "artwork", in: morph)

            Text(model.nowPlaying?.title ?? "MagicPlus")
                .font(Island.Text.label)
                .foregroundStyle(model.nowPlaying == nil ? Island.Ink.secondary : Island.Ink.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}

/// Right of the notch while the panel is open: status, not headlines.
struct ExpandedTrailingView: View {
    let model: NotchModel

    var body: some View {
        HStack(spacing: Island.Space.m) {
            Spacer(minLength: 0)

            if model.micLive {
                Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(model.micMuted ? Island.Signal.danger : Island.Signal.warning)
                    .accessibilityLabel(model.micMuted ? "Microphone muted" : "Microphone in use")
            }

            if model.cameraLive {
                Circle()
                    .fill(Island.Signal.success)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Camera in use")
            }

            if model.nowPlaying != nil {
                Waveform(isPlaying: model.isPlaying, height: 11)
            }

            if model.battery.isPresent {
                IslandStatusChip(
                    systemImage: model.battery.symbolName,
                    value: Format.percent(Double(model.battery.percentage) / 100)
                )
            }
        }
    }
}

/// Thumbnail of the shot that just landed, loaded once per activity rather than per redraw.
private struct ScreenshotThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Island.Fill.regular
                    .overlay {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 10))
                            .foregroundStyle(Island.Ink.secondary)
                    }
            }
        }
        .frame(width: 30, height: 20)
        .clipShape(.rect(cornerRadius: 5, style: .continuous))
        .task(id: url) {
            let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            image = loaded
        }
    }
}
