//
//  MixerPane.swift
//  MagicPlus
//

import SwiftUI

/// Per-app volume sliders inside the expanded island, plus external display brightness.
///
/// Built from the island's own controls rather than its own: a slider that behaves subtly
/// differently from the one in the media pane is the kind of detail that reads as sloppiness
/// without anyone being able to say why.
struct MixerPane: View {
    let mixer: AudioMixerService
    let brightness: DisplayBrightnessService

    var body: some View {
        VStack(alignment: .leading, spacing: Island.Space.s) {
            if mixer.apps.isEmpty {
                IslandEmptyState(
                    systemImage: "slider.horizontal.3",
                    title: "Nothing is playing right now",
                    message: "Apps appear here as soon as they make a sound."
                )
                .frame(height: brightness.displays.isEmpty ? Island.paneHeight : 104)
            } else {
                if mixer.needsPermission {
                    permissionHint
                }
                ForEach(mixer.apps.prefix(5)) { app in
                    MixerRow(app: app) { mixer.setVolume($0, for: app) }
                }
            }

            if !brightness.displays.isEmpty {
                displaysSection
            }
        }
        .task {
            // Live refresh while the pane is on screen; cancelled the moment it leaves.
            brightness.refresh()
            while !Task.isCancelled {
                mixer.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// DDC brightness for external displays; hidden entirely on a bare laptop.
    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: Island.Space.s) {
            HStack(spacing: Island.Space.xs) {
                Image(systemName: "sun.max")
                    .font(.system(size: 9, weight: .semibold))
                Text("Displays")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Island.Ink.tertiary)
            .padding(.top, Island.Space.xs)

            ForEach(brightness.displays) { display in
                HStack(spacing: Island.Space.s) {
                    Image(systemName: "display")
                        .font(.system(size: 11))
                        .foregroundStyle(Island.Ink.secondary)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(display.name)
                            .font(Island.Text.label)
                            .foregroundStyle(Island.Ink.primary)
                            .lineLimit(1)

                        HStack(spacing: Island.Space.s) {
                            Image(systemName: "sun.min")
                                .font(.system(size: 9))
                                .foregroundStyle(Island.Ink.tertiary)
                                .frame(width: 14)

                            IslandSlider(value: display.percent) { brightness.setBrightness($0, for: display) }

                            Text(Format.percent(display.percent))
                                .font(Island.Text.numericSmall)
                                .foregroundStyle(Island.Ink.secondary)
                                .frame(width: 38, alignment: .trailing)
                                .contentTransition(.numericText())
                                .motion(Motion.snappy, value: display.percent)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(display.name) brightness")
                .accessibilityValue(Format.percent(display.percent))
            }
        }
    }

    private var permissionHint: some View {
        HStack(spacing: Island.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Island.Signal.warning)

            Text("Allow MagicPlus under Screen & System Audio Recording to control app volume")
                .font(Island.Text.caption)
                .foregroundStyle(Island.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Island.Space.xs)

            IslandChipButton(title: "Open", isProminent: true) {
                guard let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                ) else { return }
                NSWorkspace.shared.open(url)
            }
        }
        .padding(Island.Space.s)
        .background(Island.Fill.subtle, in: .rect(cornerRadius: Island.Radius.tile, style: .continuous))
    }
}

private struct MixerRow: View {
    let app: MixerApp
    let onVolume: (Double) -> Void

    private var isMuted: Bool { app.volume < 0.005 }

    /// Background helpers report their bundle identifier instead of a name. The last
    /// component is at least a word rather than a paragraph of reverse DNS.
    private var displayName: String {
        guard app.name.contains("."), !app.name.contains(" "),
              let last = app.name.split(separator: ".").last, last.count > 1
        else { return app.name }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    var body: some View {
        HStack(spacing: Island.Space.s) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .foregroundStyle(Island.Ink.tertiary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Island.Space.xs) {
                    Text(displayName)
                        .font(Island.Text.label)
                        .foregroundStyle(Island.Ink.primary)
                        .lineLimit(1)
                    if app.isPlaying {
                        Waveform(isPlaying: true, barCount: 3, height: 8)
                    }
                }

                HStack(spacing: Island.Space.s) {
                    Button {
                        onVolume(isMuted ? 1.0 : 0.0)
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(isMuted ? Island.Signal.danger : Island.Ink.tertiary)
                            .frame(width: 14)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(isMuted ? "Unmute" : "Mute this app")

                    IslandSlider(
                        value: app.volume,
                        tint: isMuted ? Island.Signal.danger.opacity(0.8) : Island.Ink.primary.opacity(0.9),
                        onChange: onVolume
                    )

                    Text(Format.percent(app.volume))
                        .font(Island.Text.numericSmall)
                        .foregroundStyle(Island.Ink.secondary)
                        .frame(width: 38, alignment: .trailing)
                        .contentTransition(.numericText())
                        .motion(Motion.snappy, value: app.volume)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name) volume")
        .accessibilityValue(Format.percent(app.volume))
    }
}
