//
//  HardwareService.swift
//  tabmenu
//

import Foundation
import Observation

/// Runs the SMC and battery reads off the main thread and serialises them, so a slow read can
/// never overlap the next tick or block the UI.
actor HardwareCollector {
    private let sensorSampler = SensorSampler()
    private let batterySampler = BatterySampler()

    func snapshot() -> (sensors: SensorSnapshot, battery: BatteryCondition) {
        (sensorSampler.sample(), batterySampler.sample())
    }
}

/// Temperatures, fans and battery condition, sampled only while something is showing them.
@Observable
@MainActor
final class HardwareService {
    /// Sampling cadence follows what is on screen. A full sensor pass is dozens of IOKit
    /// round trips, so nothing is read at all unless something is showing it.
    enum Mode: Equatable {
        case suspended
        /// Only the menu bar readout is visible.
        case background
        /// The popover is open on the dashboard.
        case detailed

        var interval: TimeInterval {
            switch self {
            case .suspended: 0
            case .background: 10
            case .detailed: 3
            }
        }
    }

    private(set) var sensors = SensorSnapshot()
    private(set) var battery = BatteryCondition()
    private(set) var mode: Mode = .suspended

    @ObservationIgnored private let collector = HardwareCollector()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

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

    /// Hottest CPU sensor, which is the one number worth putting in the menu bar.
    var cpuTemperature: Double? { sensors.hottest(in: .cpu) }

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

        refreshTask = Task { [collector] in
            let latest = await collector.snapshot()
            guard !Task.isCancelled else { return }
            self.sensors = latest.sensors
            self.battery = latest.battery
            self.refreshTask = nil
        }
    }
}
