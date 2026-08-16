//
//  SystemStatus.swift
//  tabmenu
//

import Foundation
import IOKit.ps

nonisolated struct BatteryStatus: Equatable, Sendable {
    let percentage: Int
    let isCharging: Bool
    let isPresent: Bool

    var symbolName: String {
        guard isPresent else { return "powerplug" }
        if isCharging { return "battery.100.bolt" }
        switch percentage {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<70: return "battery.50"
        case ..<95: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// Small system readings shown in the notch panel.
nonisolated enum SystemStatus {
    // MARK: - Battery

    static func battery() -> BatteryStatus {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return BatteryStatus(percentage: 100, isCharging: false, isPresent: false) }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int,
                maximum > 0
            else { continue }

            let state = description[kIOPSPowerSourceStateKey] as? String
            return BatteryStatus(
                percentage: Int((Double(capacity) / Double(maximum) * 100).rounded()),
                isCharging: state == kIOPSACPowerValue,
                isPresent: true
            )
        }

        return BatteryStatus(percentage: 100, isCharging: false, isPresent: false)
    }
}
