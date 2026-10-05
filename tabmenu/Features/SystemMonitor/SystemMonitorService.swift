//
//  SystemMonitorService.swift
//  tabmenu
//

import Foundation
import Observation

nonisolated struct SystemSnapshot: Sendable, Equatable {
    var cpu = CPULoad()
    var memory = MemoryUsage()
    var network = NetworkThroughput()
    var disk = DiskUsage()
    var processes: [ProcessUsage] = []
    var thermal: ThermalPressure = .nominal
}

/// How hard the system says it is being pushed.
///
/// This is `ProcessInfo.thermalState`, not a sensor reading, and the dashboard shows both
/// because they answer different questions: `SensorSampler` reports what each sensor in the
/// machine says, while thermal pressure is the signal the system itself throttles on.
nonisolated enum ThermalPressure: String, Sendable, Equatable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var title: String {
        switch self {
        case .nominal: String(localized: "Normal", comment: "Thermal pressure level")
        case .fair: String(localized: "Warm", comment: "Thermal pressure level")
        case .serious: String(localized: "Hot", comment: "Thermal pressure level")
        case .critical: String(localized: "Throttling", comment: "Thermal pressure level")
        }
    }

    /// Only worth showing once the machine is actually under pressure.
    var isNoteworthy: Bool { self != .nominal }

    var ratio: Double {
        switch self {
        case .nominal: 0.15
        case .fair: 0.45
        case .serious: 0.75
        case .critical: 1
        }
    }
}

/// Fixed-length series backing the sparklines.
struct MetricHistory: Equatable {
    private(set) var samples: [Double] = []
    var capacity = 48

    mutating func append(_ value: Double) {
        samples.append(value)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Scales the series into `0...1` against its own peak, so throughput graphs stay
    /// readable regardless of absolute magnitude.
    func normalized(minimumPeak: Double = 0.0001) -> [Double] {
        let peak = max(samples.max() ?? 0, minimumPeak)
        return samples.map { $0 / peak }
    }
}

/// Runs the samplers off the main thread and serialises them, so a slow sample can never
/// overlap the next tick.
actor MetricsCollector {
    private let cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private let networkSampler = NetworkSampler()
    private let diskSampler = DiskSampler()
    private let processSampler = ProcessSampler()

    func snapshot(includeProcesses: Bool) -> SystemSnapshot {
        SystemSnapshot(
            cpu: cpuSampler.sample(),
            memory: memorySampler.sample(),
            network: networkSampler.sample(),
            disk: diskSampler.sample(),
            processes: includeProcesses ? processSampler.sample() : [],
            thermal: ThermalPressure(ProcessInfo.processInfo.thermalState)
        )
    }
}

@Observable
@MainActor
final class SystemMonitorService {
    /// Sampling cadence follows what the UI actually shows, to keep idle cost near zero.
    enum Mode: Equatable {
        /// Nothing on screen needs metrics.
        case suspended
        /// Only the menu bar label is visible.
        case background
        /// The popover is open and shows the full dashboard.
        case detailed

        var interval: TimeInterval {
            switch self {
            case .suspended: 0
            case .background: 3
            case .detailed: 1.5
            }
        }

        var includesProcesses: Bool { self == .detailed }
    }

    private(set) var snapshot = SystemSnapshot()
    private(set) var cpuHistory = MetricHistory()
    private(set) var memoryHistory = MetricHistory()
    private(set) var downloadHistory = MetricHistory()
    private(set) var uploadHistory = MetricHistory()

    @ObservationIgnored private let collector = MetricsCollector()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private(set) var mode: Mode = .suspended

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        restartTimer()
        if newMode != .suspended { refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func record(_ snapshot: SystemSnapshot) {
        cpuHistory.append(snapshot.cpu.total)
        memoryHistory.append(snapshot.memory.pressure)
        downloadHistory.append(snapshot.network.downloadBytesPerSecond)
        uploadHistory.append(snapshot.network.uploadBytesPerSecond)
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard mode != .suspended else { return }

        timer = Timer.scheduledTimer(withTimeInterval: mode.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        let includeProcesses = mode.includesProcesses

        refreshTask = Task { [collector] in
            let latest = await collector.snapshot(includeProcesses: includeProcesses)
            guard !Task.isCancelled else { return }
            self.snapshot = latest
            self.record(latest)
            self.refreshTask = nil
        }
    }
}
