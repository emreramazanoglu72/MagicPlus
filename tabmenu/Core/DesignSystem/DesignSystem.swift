//
//  DesignSystem.swift
//  tabmenu
//

import SwiftUI

enum Metrics {
    static let panelWidth: CGFloat = 360
    static let cornerRadius: CGFloat = 10
    static let cardRadius: CGFloat = 14
    static let spacing: CGFloat = 10
    static let tightSpacing: CGFloat = 6
}

/// Per-feature accent colours. Each surface carries its own hue so the three modules stay
/// distinguishable at a glance while sharing one visual language.
enum Accent {
    static let windows = Color.blue
    static let clipboard = Color.purple
    static let cpu = Color.blue
    static let memory = Color.purple
    static let disk = Color.orange
    static let network = Color.teal
    static let keepAwake = Color.yellow

    /// Green through amber to red as a resource approaches saturation.
    static func pressure(_ value: Double) -> Color {
        switch value {
        case ..<0.6: .green
        case ..<0.85: .orange
        default: .red
        }
    }
}

/// Translucent container built on the system glass material, optionally tinted by feature.
struct GlassCard<Content: View>: View {
    var tint: Color?
    var spacing: CGFloat = Metrics.tightSpacing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular.tint(tint?.opacity(0.16)),
            in: .rect(cornerRadius: Metrics.cardRadius)
        )
    }
}

struct SectionHeader: View {
    let title: String
    var systemImage: String?
    var tint: Color = .secondary
    var trailing: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Numeric readout that rolls between values instead of snapping.
struct RollingValue: View {
    let text: String
    var font: Font = .callout.monospacedDigit().weight(.medium)

    var body: some View {
        Text(text)
            .font(font)
            .contentTransition(.numericText())
            .motion(Motion.metric, value: text)
    }
}

/// Horizontal usage bar that shifts hue as pressure increases.
struct UsageBar: View {
    let value: Double
    var height: CGFloat = 5
    var tint: Color?

    private var resolvedTint: Color { tint ?? Accent.pressure(value) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(resolvedTint.gradient)
                    .frame(width: max(2, proxy.size.width * value.clampedToUnitRange))
                    .shadow(color: resolvedTint.opacity(0.5), radius: 3, y: 1)
            }
        }
        .frame(height: height)
        .motion(Motion.metric, value: value)
    }
}

/// Row-level button styling used inside popover and panel lists.
struct PanelRowButtonStyle: ButtonStyle {
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(isPressed: configuration.isPressed), in: .rect(cornerRadius: 9))
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .motion(Motion.snappy, value: configuration.isPressed)
    }

    private func background(isPressed: Bool) -> AnyShapeStyle {
        if isPressed { return AnyShapeStyle(.tint.opacity(0.3)) }
        return AnyShapeStyle(.clear)
    }
}

/// Keyboard hint chip shown in panel footers.
struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.caption2.monospaced().weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 4))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(keys)")
    }
}

extension Double {
    var clampedToUnitRange: Double { min(max(self, 0), 1) }
}
