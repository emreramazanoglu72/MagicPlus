//
//  BatterySampler.swift
//  tabmenu
//

import Foundation
import IOKit
import IOKit.ps

/// What the battery is doing, and how it is holding up.
nonisolated struct BatteryCondition: Sendable, Equatable {
    var isPresent = false
    /// Charge level, 0...1.
    var percentage: Double = 0
    var isCharging = false
    var isPluggedIn = false
    var cycleCount = 0
    /// Full-charge capacity against the capacity the battery shipped with, 0...1.
    var healthRatio: Double = 0
    /// Degrees Celsius, 0 when the battery does not report it.
    var temperature: Double = 0
    /// Milliamps; negative while discharging.
    var amperage: Double = 0
    var voltage: Double = 0
    var designCapacity = 0
    var fullChargeCapacity = 0
    /// Minutes, or nil while the estimate is still settling.
    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var needsService = false

    var isHealthKnown: Bool { healthRatio > 0 }
}

/// Reads the battery twice over: the public power-source API for the state everyone agrees
/// on, and the battery's own registry entry for the details it is the only source of.
nonisolated final class BatterySampler {
    func sample() -> BatteryCondition {
        var status = powerSourceStatus()
        applyRegistryDetails(to: &status)
        return status
    }

    /// `IOPowerSources` is public, stable, and already knows how macOS itself rounds the
    /// percentage and estimates the remaining time.
    private func powerSourceStatus() -> BatteryCondition {
        var status = BatteryCondition()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return status }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 0

            status.isPresent = true
            status.percentage = maximum > 0 ? Double(current) / Double(maximum) : 0
            status.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            status.isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            status.minutesToFull = positiveMinutes(description[kIOPSTimeToFullChargeKey])
            status.minutesToEmpty = positiveMinutes(description[kIOPSTimeToEmptyKey])
            break
        }
        return status
    }

    /// Cycle count, health and temperature live only on the battery's registry entry.
    private func applyRegistryDetails(to status: inout BatteryCondition) {
        guard let properties = batteryProperties() else { return }

        status.isPresent = status.isPresent || (properties["BatteryInstalled"] as? Bool ?? false)
        status.cycleCount = properties["CycleCount"] as? Int ?? 0
        status.designCapacity = properties["DesignCapacity"] as? Int ?? 0
        status.needsService = (properties["PermanentFailureStatus"] as? Int ?? 0) != 0

        // Which key carries the full-charge capacity has moved around between releases, so
        // the most specific one that is actually present wins.
        let capacityKeys = ["NominalChargeCapacity", "AppleRawMaxCapacity", "MaxCapacity"]
        if let fullCharge = capacityKeys.lazy.compactMap({ properties[$0] as? Int }).first(where: { $0 > 0 }) {
            status.fullChargeCapacity = fullCharge
            if status.designCapacity > 0 {
                let ratio = Double(fullCharge) / Double(status.designCapacity)
                // A percentage-shaped MaxCapacity (the old 0...100 form) would read as 1% of
                // the design capacity; only a plausible ratio is reported as health.
                status.healthRatio = (0.2...1.2).contains(ratio) ? min(ratio, 1) : 0
            }
        }

        if let raw = properties["Temperature"] as? Int {
            let celsius = Double(raw) / 100
            status.temperature = (0...100).contains(celsius) ? celsius : 0
        }
        if let amperage = properties["Amperage"] as? Int {
            status.amperage = Double(amperage)
        }
        if let voltage = properties["Voltage"] as? Int {
            status.voltage = Double(voltage) / 1_000
        }
    }

    private func batteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess
        else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    /// The time estimates report -1 while macOS is still working them out.
    private func positiveMinutes(_ value: Any?) -> Int? {
        guard let minutes = value as? Int, minutes > 0 else { return nil }
        return minutes
    }
}
