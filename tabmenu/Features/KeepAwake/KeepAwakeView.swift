//
//  KeepAwakeView.swift
//  tabmenu
//

import SwiftUI

/// Full keep-awake control: the switch, a live countdown, and one-tap durations.
struct KeepAwakeCard: View {
    let service: KeepAwakeService

    var body: some View {
        GlassCard(tint: service.isActive ? Accent.keepAwake : nil) {
            header
            Text(service.isActive ? Self.activeCaption : Self.idleCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            durations
        }
        .motion(Motion.fluid, value: service.isActive)
    }

    private static let activeCaption =
        "Display sleep, system sleep, disk spin-down and the idle lock are held off."
    private static let idleCaption =
        "The Mac sleeps and locks on its own schedule."

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: service.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(service.isActive ? AnyShapeStyle(Accent.keepAwake) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: service.isActive)

            Text("Keep Awake")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if let remaining = service.remaining {
                RollingValue(text: Format.countdown(remaining), font: .caption.monospacedDigit())
                    .foregroundStyle(Accent.keepAwake)
                    .accessibilityLabel("Time remaining")
            }

            Toggle("Keep Awake", isOn: service.binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    /// Tapping a duration starts a session with it, so switching on and choosing how long
    /// take one gesture rather than two.
    private var durations: some View {
        HStack(spacing: 4) {
            ForEach(KeepAwakeDuration.allCases) { duration in
                DurationChip(
                    duration: duration,
                    isSelected: (service.activeDuration ?? service.selectedDuration) == duration,
                    isActive: service.isActive
                ) {
                    service.activate(for: duration)
                }
            }
        }
    }
}

private struct DurationChip: View {
    let duration: KeepAwakeDuration
    let isSelected: Bool
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var isHighlighted: Bool { isSelected && isActive }

    var body: some View {
        Button(action: action) {
            Text(duration.shortTitle)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(isHighlighted ? AnyShapeStyle(Accent.keepAwake) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background {
                    Capsule()
                        .fill(Accent.keepAwake.opacity(isHighlighted ? 0.22 : (isHovered ? 0.1 : 0)))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(.quaternary, lineWidth: isSelected && !isActive ? 1 : 0)
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .motion(Motion.snappy, value: isHighlighted)
        .help("Keep awake \(duration.title.lowercased())")
        .accessibilityLabel("Keep awake \(duration.title.lowercased())")
        .accessibilityAddTraits(isHighlighted ? [.isSelected, .isButton] : .isButton)
    }
}

/// Compact on/off button for the popover header, so keep-awake is one click away from any tab.
struct KeepAwakeHeaderButton: View {
    let service: KeepAwakeService

    @State private var isHovered = false

    var body: some View {
        Button { service.toggle() } label: {
            Image(systemName: service.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 12))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .background(
                    service.isActive
                        ? AnyShapeStyle(Accent.keepAwake.opacity(0.22))
                        : AnyShapeStyle(.quaternary.opacity(isHovered ? 0.7 : 0)),
                    in: .circle
                )
                .contentShape(.circle)
                .symbolEffect(.bounce, value: service.isActive)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .motion(Motion.snappy, value: service.isActive)
        .contextMenu {
            Picker("Keep awake for", selection: service.durationBinding) {
                ForEach(KeepAwakeDuration.allCases) { duration in
                    Text(duration.title).tag(duration)
                }
            }
            .pickerStyle(.inline)

            if service.isActive {
                Divider()
                Button("Turn Off") { service.deactivate() }
            }
        }
        .help(helpText)
        .accessibilityLabel("Keep Awake")
        .accessibilityValue(service.isActive ? "On" : "Off")
        .accessibilityAddTraits(service.isActive ? [.isSelected] : [])
    }

    private var foreground: AnyShapeStyle {
        if service.isActive { return AnyShapeStyle(Accent.keepAwake) }
        return AnyShapeStyle(isHovered ? .primary : .secondary)
    }

    private var helpText: String {
        guard service.isActive else {
            return String(localized: "Keep the Mac awake", comment: "Help tag for the keep-awake button while off")
        }
        return service.statusText
    }
}

extension KeepAwakeService {
    /// Switch binding for SwiftUI toggles.
    var binding: Binding<Bool> {
        Binding(
            get: { self.isActive },
            set: { isOn in
                if isOn {
                    self.activate(for: self.selectedDuration)
                } else {
                    self.deactivate()
                }
            }
        )
    }

    /// Picking a duration also arms the session, matching the chips in the card.
    var durationBinding: Binding<KeepAwakeDuration> {
        Binding(
            get: { self.activeDuration ?? self.selectedDuration },
            set: { self.activate(for: $0) }
        )
    }
}
