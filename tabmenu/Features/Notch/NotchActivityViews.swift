//
//  NotchActivityViews.swift
//  tabmenu
//

import SwiftUI

/// Left of the notch during a transient activity: always a single glyph or the artwork, so
/// the eye lands in the same place whatever happened.
struct ActivityLeadingView: View {
    let activity: NotchActivity
    let model: NotchModel
    let morph: Namespace.ID

    var body: some View {
        HStack(spacing: 7) {
            switch activity {
            case .nowPlaying:
                ArtworkTile(image: model.artwork, size: 22, cornerRadius: 6)
                    .matchedGeometryEffect(id: "artwork", in: morph)
                Waveform(isPlaying: model.isPlaying, height: 12)

            case .volume(let level):
                Image(systemName: volumeSymbol(for: level))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)

            case .meeting(let event):
                Circle()
                    .fill(event.calendarColor)
                    .frame(width: 8, height: 8)
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)

            case .filesAdded:
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Accent.windows)
                    .symbolEffect(.bounce, value: activity)

            case .screenshot(let url):
                ScreenshotThumbnail(url: url)

            case .download:
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: activity)

            case .micStatus(let muted):
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(muted ? .red : .orange)
                    .contentTransition(.symbolEffect(.replace))

            case .textCaptured:
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 13))
                    .foregroundStyle(Accent.clipboard)
                    .symbolEffect(.bounce, value: activity)

            case .lowBattery:
                Image(systemName: "battery.25")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)

            case .diskFull:
                Image(systemName: "externaldrive.fill.badge.exclamationmark")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .symbolEffect(.bounce, value: activity)

            case .windowsRescued:
                Image(systemName: "macwindow.and.cursorarrow")
                    .font(.system(size: 13))
                    .foregroundStyle(Accent.windows)
                    .symbolEffect(.bounce, value: activity)

            case .sleepDespiteKeepAwake:
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.pulse)

            case .power(let isCharging, _):
                Image(systemName: isCharging ? "bolt.fill" : "powerplug.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isCharging ? .green : .orange)
                    .symbolEffect(.bounce, value: activity)
            }

            Spacer(minLength: 0)
        }
    }

    private func volumeSymbol(for level: Double) -> String {
        switch level {
        case ..<0.001: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// Right of the notch: the detail that explains the glyph on the left.
struct ActivityTrailingView: View {
    let activity: NotchActivity
    let model: NotchModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            switch activity {
            case .nowPlaying(let info):
                VStack(alignment: .trailing, spacing: 0) {
                    Text(info.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(info.artist)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .truncationMode(.tail)

            case .volume(let level):
                HStack(spacing: 6) {
                    LevelBar(value: level, tint: .cyan)
                        .frame(width: 46)
                    Text(Format.percent(level))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }

            case .meeting(let event):
                HStack(spacing: 7) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(event.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(event.countdownLabel())
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(event.isInProgress ? .green : .white.opacity(0.6))
                    }
                    if event.meetingURL != nil {
                        // The whole capsule is the click target; this is the affordance.
                        Text("Join")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.white, in: .capsule)
                    }
                }

            case .filesAdded(let count):
                Text("\(count) files")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)

            case .screenshot:
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Screenshot")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Added to shelf")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }

            case .download(let name):
                VStack(alignment: .trailing, spacing: 0) {
                    Text(name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Downloaded")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }

            case .micStatus(let muted):
                Text(muted ? "Mic muted" : "Mic live")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(muted ? .red : .white)

            case .textCaptured(let characters):
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(characters) characters")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Copied as text")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }

            case .lowBattery(let percentage):
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(percentage)%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.red)
                    Text("Low battery")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }

            case .diskFull(let freeBytes):
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.bytes(freeBytes))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("Disk almost full")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

            case .windowsRescued(let count):
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(count) windows")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Back on screen")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }

            case .sleepDespiteKeepAwake:
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Mac slept despite Keep Awake")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Lid closed or forced sleep")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }

            case .power(let isCharging, let percentage):
                HStack(spacing: 5) {
                    Text("\(percentage)%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Image(systemName: isCharging ? "battery.100.bolt" : "battery.50")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}

/// Left of the notch while the panel is open.
struct ExpandedLeadingView: View {
    let model: NotchModel
    let morph: Namespace.ID

    var body: some View {
        HStack(spacing: 7) {
            ArtworkTile(image: model.artwork, size: 22, cornerRadius: 6)
                .matchedGeometryEffect(id: "artwork", in: morph)

            Text(model.nowPlaying?.title ?? "MagicPlus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}

/// Right of the notch while the panel is open: quiet status, not a headline.
struct ExpandedTrailingView: View {
    let model: NotchModel

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            if model.battery.isPresent {
                HStack(spacing: 3) {
                    Image(systemName: model.battery.symbolName)
                        .font(.system(size: 10))
                    Text("\(model.battery.percentage)%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(.white.opacity(0.6))
            }

            if model.nowPlaying != nil {
                Waveform(isPlaying: model.isPlaying, height: 12)
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
                Color.white.opacity(0.14)
                    .overlay {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                    }
            }
        }
        .frame(width: 30, height: 20)
        .clipShape(.rect(cornerRadius: 4, style: .continuous))
        .task(id: url) {
            let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            image = loaded
        }
    }
}

// MARK: - Shared pieces

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
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white.opacity(0.16))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(.white.opacity(0.7))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Filled capsule used for volume and playback position.
struct LevelBar: View {
    let value: Double
    var tint: Color = .white
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width * value.clampedToUnitRange))
            }
        }
        .frame(height: height)
        .motion(Motion.snappy, value: value)
    }
}
