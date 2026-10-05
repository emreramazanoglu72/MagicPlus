//
//  SensorSampler.swift
//  tabmenu
//

import Foundation

/// Reads the machine's temperature sensors and fans out of the SMC.
///
/// Which keys exist differs with every Mac, so the list is discovered once from the SMC's own
/// index and then reused: enumerating is expensive, reading a known key is not. Keys that
/// report an implausible temperature are dropped during discovery rather than filtered on
/// every tick — a sensor that reads 0°C on this machine will read 0°C on the next tick too.
nonisolated final class SensorSampler {
    private let connection = SMCConnection()
    private var temperatureKeys: [String]?
    private var fanIndices: [Int]?

    /// Enough to cover every core on a Max-class chip without turning a tick into a scan.
    private static let maximumSensors = 48
    private static let plausibleRange: ClosedRange<Double> = 1...150

    var isAvailable: Bool { connection != nil }

    func sample() -> SensorSnapshot {
        guard let connection else { return SensorSnapshot(isAvailable: false) }

        let keys = temperatureKeys ?? discoverTemperatureKeys(connection)
        temperatureKeys = keys

        let sensors = keys.compactMap { key -> SensorReading? in
            guard let value = connection.read(key: key), Self.plausibleRange.contains(value) else { return nil }
            return SensorReading(key: key, category: .forKey(key), celsius: value)
        }

        return SensorSnapshot(sensors: sensors, fans: readFans(connection), isAvailable: true)
    }

    // MARK: - Discovery

    private func discoverTemperatureKeys(_ connection: SMCConnection) -> [String] {
        let candidates = connection.allKeys().filter { $0.hasPrefix("T") }

        let live = candidates.filter { key in
            guard let value = connection.read(key: key) else { return false }
            return Self.plausibleRange.contains(value)
        }

        // Named groups first: on a machine with more sensors than the cap, the ones the
        // dashboard actually shows must be the ones that survive.
        return Array(
            live.sorted { first, second in
                let firstRank = SensorCategory.forKey(first) == .other ? 1 : 0
                let secondRank = SensorCategory.forKey(second) == .other ? 1 : 0
                return firstRank == secondRank ? first < second : firstRank < secondRank
            }
            .prefix(Self.maximumSensors)
        )
    }

    // MARK: - Fans

    private func readFans(_ connection: SMCConnection) -> [FanReading] {
        let indices = fanIndices ?? discoverFans(connection)
        fanIndices = indices

        return indices.compactMap { index in
            guard let actual = connection.read(key: "F\(index)Ac") else { return nil }
            return FanReading(
                index: index,
                actual: actual,
                minimum: connection.read(key: "F\(index)Mn") ?? 0,
                maximum: connection.read(key: "F\(index)Mx") ?? max(actual, 1)
            )
        }
    }

    private func discoverFans(_ connection: SMCConnection) -> [Int] {
        guard let count = connection.read(key: "FNum"), count >= 1 else { return [] }
        return Array(0..<Int(count))
    }
}
