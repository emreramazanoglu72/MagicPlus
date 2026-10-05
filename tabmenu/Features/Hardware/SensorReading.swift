//
//  SensorReading.swift
//  tabmenu
//

import Foundation
import SwiftUI

/// What part of the machine a temperature sensor is attached to.
///
/// The SMC hands out four-character keys and nothing else — no names, no units, no grouping.
/// The prefixes below are the ones Apple has used consistently across Intel and Apple
/// Silicon; anything unrecognised is still reported, just without a home.
nonisolated enum SensorCategory: String, Sendable, CaseIterable, Identifiable, Codable {
    case cpu
    case gpu
    case battery
    case ambient
    case storage
    case power
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: String(localized: "CPU", comment: "Temperature sensor group")
        case .gpu: String(localized: "GPU", comment: "Temperature sensor group")
        case .battery: String(localized: "Battery", comment: "Temperature sensor group")
        case .ambient: String(localized: "Ambient", comment: "Temperature sensor group")
        case .storage: String(localized: "Storage", comment: "Temperature sensor group")
        case .power: String(localized: "Power", comment: "Temperature sensor group")
        case .other: String(localized: "Other", comment: "Temperature sensor group")
        }
    }

    var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "cpu.fill"
        case .battery: "battery.100percent"
        case .ambient: "thermometer.medium"
        case .storage: "internaldrive"
        case .power: "bolt"
        case .other: "sensor"
        }
    }

    /// Groups worth a row of their own in the dashboard, in the order they are shown.
    static let displayed: [SensorCategory] = [.cpu, .gpu, .battery, .ambient, .storage]

    /// Reads the group out of an SMC key. Intel and Apple Silicon spell the same sensor
    /// differently, so both spellings are listed.
    static func forKey(_ key: String) -> SensorCategory {
        let prefix = String(key.prefix(2))
        switch prefix {
        case "TC", "Tp", "TP": return .cpu
        case "TG", "Tg": return .gpu
        case "TB", "Tb": return .battery
        case "TA", "Ta", "Ts", "TS": return .ambient
        case "TH", "TN": return .storage
        case "Tm", "TM", "TW", "Te": return .power
        default: return .other
        }
    }
}

nonisolated struct SensorReading: Sendable, Equatable, Identifiable {
    let key: String
    let category: SensorCategory
    /// Degrees Celsius.
    let celsius: Double

    var id: String { key }
}

/// One fan, as the SMC describes it. Machines without fans report none, which is the normal
/// case for the MacBook Air and the mini.
nonisolated struct FanReading: Sendable, Equatable, Identifiable {
    let index: Int
    let actual: Double
    let minimum: Double
    let maximum: Double

    var id: Int { index }

    /// Where the fan sits between its own limits, for the gauge.
    var ratio: Double {
        let range = maximum - minimum
        guard range > 0 else { return 0 }
        return ((actual - minimum) / range).clampedToUnitRange
    }

    var isSpinning: Bool { actual > 1 }
}

nonisolated struct SensorSnapshot: Sendable, Equatable {
    var sensors: [SensorReading] = []
    var fans: [FanReading] = []
    /// False on a Mac whose SMC refuses to open, which is what a virtual machine does.
    var isAvailable = false

    /// The hottest reading in a group. A Mac reports a dozen CPU sensors and the highest one
    /// is the number that matters; averaging them just hides the hot core.
    func hottest(in category: SensorCategory) -> Double? {
        sensors.filter { $0.category == category }.map(\.celsius).max()
    }

    var hottest: SensorReading? {
        sensors.max { $0.celsius < $1.celsius }
    }

    var hasReadings: Bool { !sensors.isEmpty || !fans.isEmpty }
}
