//
//  MixerPane.swift
//  MagicPlus
//

import SwiftUI

/// Per-app volume sliders inside the expanded island.
struct MixerPane: View {
    let mixer: AudioMixerService
    let brightness: DisplayBrightnessService

    var body: some View {
        Group {
            VStack(spacing: 7) {
                if mixer.apps.isEmpty {
                    emptyState
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
        }
        .frame(minHeight: 92)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sun.max")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Displays")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .padding(.top, 2)

            ForEach(brightness.displays) { display in
                HStack(spacing: 9) {
                    Image(systemName: "display")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(display.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 7) {
                            Image(systemName: "sun.min")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 14)
                            MixerSlider(value: display.percent) { brightness.setBrightness($0, for: display) }
                            Text(Format.percent(display.percent))
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
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

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.5))
            Text("Nothing is playing right now")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var permissionHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text("Allow MagicPlus under Screen & System Audio Recording to control app volume")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.white, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

private struct MixerRow: View {
    let app: MixerApp
    let onVolume: (Double) -> Void

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if app.isPlaying {
                        Waveform(isPlaying: true, barCount: 3, height: 8)
                    }
                }

                HStack(spacing: 7) {
                    Button {
                        onVolume(app.volume < 0.005 ? 1.0 : 0.0)
                    } label: {
                        Image(systemName: app.volume < 0.005 ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(app.volume < 0.005 ? .red : .white.opacity(0.5))
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                    .help(app.volume < 0.005 ? "Unmute" : "Mute this app")

                    MixerSlider(value: app.volume, onChange: onVolume)

                    Text(Format.percent(app.volume))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
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

private struct MixerSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule()
                    .fill(value < 0.005 ? AnyShapeStyle(.red.opacity(0.7)) : AnyShapeStyle(.white.opacity(0.85)))
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
        .motion(Motion.snappy, value: value)
    }
}
