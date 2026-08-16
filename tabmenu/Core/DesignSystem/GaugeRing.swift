//
//  GaugeRing.swift
//  tabmenu
//

import SwiftUI

/// Circular resource gauge with a glowing progress arc and a rolling numeric readout.
struct GaugeRing: View {
    let value: Double
    let title: String
    let caption: String
    var tint: Color
    var size: CGFloat = 92
    var lineWidth: CGFloat = 9

    private var clamped: Double { value.clampedToUnitRange }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.quaternary, style: .init(lineWidth: lineWidth, lineCap: .round))

                Circle()
                    .trim(from: 0, to: max(0.001, clamped))
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.55), tint, tint.opacity(0.85)],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        style: .init(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.55), radius: 6)
                    .motion(Motion.metric, value: clamped)

                VStack(spacing: 0) {
                    Text(Format.percent(clamped))
                        .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .motion(Motion.metric, value: clamped)
                    Text(title)
                        .font(.system(size: size * 0.11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.5)
                }
            }
            .frame(width: size, height: size)

            Text(caption)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Format.percent(clamped)), \(caption)")
    }
}
