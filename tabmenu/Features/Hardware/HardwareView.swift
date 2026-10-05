//
//  HardwareView.swift
//  tabmenu
//

import SwiftUI

/// Temperatures and fans, as the SMC reports them.
struct SensorsCard: View {
    let service: HardwareService

    private var snapshot: SensorSnapshot { service.sensors }

    var body: some View {
        GlassCard(tint: .red) {
            SectionHeader(
                title: String(localized: "Temperatures", comment: "Sensor card heading"),
                systemImage: "thermometer.medium",
                tint: .red,
                trailing: snapshot.hottest.map { Format.celsius($0.celsius) }
            )

            if !snapshot.isAvailable {
                Text("This Mac does not expose its sensors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !snapshot.hasReadings {
                Text("Reading sensors…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(SensorCategory.displayed) { category in
                    if let celsius = snapshot.hottest(in: category) {
                        temperatureRow(category: category, celsius: celsius)
                    }
                }

                if !snapshot.fans.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(snapshot.fans) { fan in
                        fanRow(fan)
                    }
                }
            }
        }
    }

    private func temperatureRow(category: SensorCategory, celsius: Double) -> some View {
        HStack(spacing: Metrics.tightSpacing) {
            Image(systemName: category.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(category.title)
                .font(.caption)
                .frame(width: 62, alignment: .leading)

            UsageBar(value: Format.temperatureRatio(celsius))

            RollingValue(text: Format.celsius(celsius), font: .caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func fanRow(_ fan: FanReading) -> some View {
        HStack(spacing: Metrics.tightSpacing) {
            Image(systemName: "fan")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .symbolEffect(.rotate, isActive: fan.isSpinning)

            Text("Fan \(fan.index + 1)")
                .font(.caption)
                .frame(width: 62, alignment: .leading)

            UsageBar(value: fan.ratio, tint: Accent.network)

            RollingValue(text: "\(Int(fan.actual)) rpm", font: .caption.monospacedDigit())
                .frame(width: 66, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Battery condition, and the control that holds it below full.
struct BatteryCard: View {
    let service: HardwareService
    let chargeLimit: ChargeLimitService
    let onOpenSettings: () -> Void

    private var battery: BatteryCondition {
        // The limit service keeps its own reading going when nothing else is sampling.
        service.battery.isPresent ? service.battery : chargeLimit.battery
    }

    var body: some View {
        if battery.isPresent {
            GlassCard(tint: .green) {
                SectionHeader(
                    title: String(localized: "Battery", comment: "Battery card heading"),
                    systemImage: "battery.100percent",
                    tint: .green,
                    trailing: Format.percent(battery.percentage)
                )

                UsageBar(value: battery.percentage, tint: chargeLimit.isHoldingCharge ? .orange : .green)

                HStack(spacing: Metrics.spacing) {
                    detail(
                        label: String(localized: "Health", comment: "Battery detail"),
                        value: battery.isHealthKnown ? Format.percent(battery.healthRatio) : "—"
                    )
                    detail(
                        label: String(localized: "Cycles", comment: "Battery detail"),
                        value: battery.cycleCount > 0 ? "\(battery.cycleCount)" : "—"
                    )
                    detail(
                        label: String(localized: "Temperature", comment: "Battery detail"),
                        value: battery.temperature > 0 ? Format.celsius(battery.temperature) : "—"
                    )
                }

                if chargeLimit.isEnabled || chargeLimit.isHoldingCharge {
                    limitRow
                }
            }
        }
    }

    /// Formatted rather than interpolated: "80%" is written differently in other locales.
    private var target: String {
        Format.percent(Double(chargeLimit.targetPercentage) / 100)
    }

    private var limitRow: some View {
        HStack(spacing: 6) {
            Image(systemName: chargeLimit.isHoldingCharge ? "pause.circle.fill" : "bolt.badge.clock")
                .font(.caption)
                .foregroundStyle(chargeLimit.isHoldingCharge ? .orange : .secondary)

            Text(
                chargeLimit.isHoldingCharge
                    ? String(localized: "Charging paused at \(target)", comment: "Charge limit state, with the target level")
                    : String(localized: "Charging up to \(target)", comment: "Charge limit state, with the target level")
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button("Settings…", action: onOpenSettings)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
