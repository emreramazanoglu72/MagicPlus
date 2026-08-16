//
//  SystemMonitorView.swift
//  tabmenu
//

import SwiftUI

struct SystemMonitorView: View {
    let service: SystemMonitorService

    private var snapshot: SystemSnapshot { service.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            gauges
            thermal
            cores
            storage
            network
            processes
        }
    }

    // MARK: - Gauges

    private var gauges: some View {
        GlassCard(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                gaugeColumn(
                    value: snapshot.cpu.total,
                    title: "CPU",
                    caption: "\(Format.percent(snapshot.cpu.user)) user · \(Format.percent(snapshot.cpu.system)) sys",
                    tint: Accent.cpu,
                    history: service.cpuHistory.samples
                )
                gaugeColumn(
                    value: snapshot.memory.pressure,
                    title: "Memory",
                    caption: "\(Format.bytes(Int64(snapshot.memory.used))) of \(Format.bytes(Int64(snapshot.memory.total)))",
                    tint: Accent.memory,
                    history: service.memoryHistory.samples
                )
            }
        }
    }

    private func gaugeColumn(
        value: Double,
        title: String,
        caption: String,
        tint: Color,
        history: [Double]
    ) -> some View {
        VStack(spacing: 4) {
            GaugeRing(value: value, title: title, caption: caption, tint: tint, size: 86)
            if history.count > 1 {
                Sparkline(samples: history, tint: tint, height: 24)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Hidden while the Mac is comfortable — a permanent "Normal" row would be noise.
    @ViewBuilder
    private var thermal: some View {
        if snapshot.thermal.isNoteworthy {
            GlassCard(tint: .orange) {
                MetricRowCompat(
                    title: String(localized: "Thermal pressure", comment: "System monitor section"),
                    value: snapshot.thermal.title,
                    ratio: snapshot.thermal.ratio
                )
            }
        }
    }

    // MARK: - Cores

    @ViewBuilder
    private var cores: some View {
        if !snapshot.cpu.cores.isEmpty {
            GlassCard {
                SectionHeader(
                    title: "Cores",
                    systemImage: "cpu",
                    tint: Accent.cpu,
                    trailing: "\(snapshot.cpu.cores.count)"
                )
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(snapshot.cpu.cores.enumerated()), id: \.offset) { index, load in
                        CoreBar(load: load, index: index)
                    }
                }
                .frame(height: 34)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Per core load")
                .accessibilityValue(snapshot.cpu.cores.map { Format.percent($0) }.joined(separator: ", "))
            }
        }
    }

    // MARK: - Storage

    private var storage: some View {
        GlassCard(tint: Accent.disk) {
            SectionHeader(title: "Disk", systemImage: "internaldrive", tint: Accent.disk)
            HStack(alignment: .firstTextBaseline) {
                RollingValue(text: Format.bytes(snapshot.disk.used))
                Text("of \(Format.bytes(snapshot.disk.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                RollingValue(text: Format.percent(snapshot.disk.ratio), font: .caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            UsageBar(value: snapshot.disk.ratio)
            HStack(spacing: 12) {
                ThroughputLabel(symbol: "arrow.down.circle", value: Format.speed(snapshot.disk.readBytesPerSecond), tint: Accent.disk)
                ThroughputLabel(symbol: "arrow.up.circle", value: Format.speed(snapshot.disk.writeBytesPerSecond), tint: Accent.disk)
            }
            .padding(.top, 1)
        }
    }

    // MARK: - Network

    private var network: some View {
        GlassCard(tint: Accent.network) {
            SectionHeader(title: "Network", systemImage: "wifi", tint: Accent.network)
            HStack(spacing: 14) {
                ThroughputLabel(
                    symbol: "arrow.down",
                    value: Format.speed(snapshot.network.downloadBytesPerSecond),
                    tint: .blue
                )
                ThroughputLabel(
                    symbol: "arrow.up",
                    value: Format.speed(snapshot.network.uploadBytesPerSecond),
                    tint: .green
                )
            }
            ZStack {
                Sparkline(samples: service.downloadHistory.normalized(), tint: .blue, height: 30)
                Sparkline(samples: service.uploadHistory.normalized(), tint: .green, height: 30)
                    .opacity(0.85)
            }
        }
    }

    // MARK: - Processes

    @ViewBuilder
    private var processes: some View {
        if !snapshot.processes.isEmpty {
            GlassCard {
                SectionHeader(title: "Top processes", systemImage: "list.bullet", trailing: "CPU")
                ForEach(snapshot.processes) { process in
                    ProcessRow(process: process)
                }
            }
        }
    }
}

/// Title, value and bar, for readings that are not a percentage.
private struct MetricRowCompat: View {
    let title: String
    let value: String
    let ratio: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout.weight(.medium))
            }
            UsageBar(value: ratio)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// Vertical bar for a single core, growing from the baseline as load rises.
private struct CoreBar: View {
    let load: Double
    let index: Int

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Accent.pressure(load).gradient)
                    .frame(height: max(3, proxy.size.height * load.clampedToUnitRange))
                    .shadow(color: Accent.pressure(load).opacity(0.45), radius: 3)
            }
        }
        .background(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.quaternary.opacity(0.5))
        }
        .motion(Motion.metric, value: load)
        .help("Core \(index + 1): \(Format.percent(load))")
    }
}

private struct ProcessRow: View {
    let process: ProcessUsage

    /// `ps` reports percentage of a single core, so the bar is scaled against one core.
    private var ratio: Double { min(process.cpuPercent / 100, 1) }

    var body: some View {
        HStack(spacing: 8) {
            Text(process.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 118, alignment: .leading)

            UsageBar(value: ratio, height: 4)

            Text("\(process.cpuPercent, specifier: "%.1f")%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(process.name): \(String(format: "%.1f", process.cpuPercent)) percent CPU")
    }
}

private struct ThroughputLabel: View {
    let symbol: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            RollingValue(text: value)
        }
        .accessibilityElement(children: .combine)
    }
}
