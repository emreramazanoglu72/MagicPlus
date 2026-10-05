//
//  ChargeControl.swift
//  MagicPlus
//

import Foundation

/// How charging can be held back on this particular Mac.
///
/// Apple exposes no API for it, and the two SMC mechanisms that exist are split along the
/// Intel/Apple Silicon line, so the right one is discovered by asking the SMC which keys it
/// has rather than by reading the model identifier.
nonisolated enum ChargeControlMechanism: String, Sendable, Codable {
    /// `BCLM` holds a maximum charge level and the firmware enforces it on its own. Intel.
    case firmwareLimit
    /// `CH0B`/`CH0C` switch charging off and on, so the level is held by toggling them as the
    /// battery crosses the target. Apple Silicon.
    case chargingSwitch
    /// Neither key is present: this Mac cannot be limited, and the UI has to say so.
    case unsupported
}

/// The SMC side of charge limiting, shared by the app (which only asks what is supported)
/// and the helper (which is root, and does the writing).
nonisolated struct ChargeControl {
    private let connection: SMCConnection

    private enum Key {
        static let firmwareLimit = "BCLM"
        /// Both switches have to move together; one on its own leaves charging in a state the
        /// firmware does not expect.
        static let chargingSwitches = ["CH0B", "CH0C"]
        /// The Intel spelling of the same switch.
        static let intelInhibit = "CH0I"
    }

    /// Values the switch keys take. Anything else is left alone.
    private enum Switch: UInt8 {
        case allowCharging = 0x00
        case inhibitCharging = 0x02
    }

    init?() {
        guard let connection = SMCConnection() else { return nil }
        self.connection = connection
    }

    init(connection: SMCConnection) {
        self.connection = connection
    }

    var mechanism: ChargeControlMechanism {
        if connection.exists(key: Key.firmwareLimit) { return .firmwareLimit }
        if Key.chargingSwitches.allSatisfy({ connection.exists(key: $0) }) { return .chargingSwitch }
        if connection.exists(key: Key.intelInhibit) { return .chargingSwitch }
        return .unsupported
    }

    /// Hands the target to the firmware, for Macs that keep it themselves.
    /// Returns false when the write did not take, which is treated as "not supported here"
    /// rather than reported as success.
    @discardableResult
    func setFirmwareLimit(percentage: Int) -> Bool {
        let clamped = UInt8(Swift.min(Swift.max(percentage, 20), 100))
        guard connection.write(key: Key.firmwareLimit, bytes: [clamped]) else { return false }
        return connection.read(key: Key.firmwareLimit).map { Int($0) == Int(clamped) } ?? false
    }

    /// Switches charging off or on. Every key that exists is written, and the result is read
    /// back: a silent refusal is the failure mode to worry about here.
    @discardableResult
    func setChargingInhibited(_ inhibited: Bool) -> Bool {
        let value = (inhibited ? Switch.inhibitCharging : .allowCharging).rawValue
        var wroteAny = false

        for key in Key.chargingSwitches where connection.exists(key: key) {
            wroteAny = connection.write(key: key, bytes: [value]) || wroteAny
        }
        if connection.exists(key: Key.intelInhibit) {
            wroteAny = connection.write(key: Key.intelInhibit, bytes: [inhibited ? 1 : 0]) || wroteAny
        }
        return wroteAny
    }

    /// Puts the machine back the way it was found: charging allowed, no firmware ceiling.
    /// Called on every path out of the helper, including the watchdog.
    func restoreDefaults() {
        _ = setChargingInhibited(false)
        if connection.exists(key: Key.firmwareLimit) {
            _ = connection.write(key: Key.firmwareLimit, bytes: [100])
        }
    }

    /// True while charging is currently held back, read from the hardware rather than from
    /// what was last written.
    var isChargingInhibited: Bool {
        for key in Key.chargingSwitches {
            if let value = connection.read(key: key), value != 0 { return true }
        }
        if let value = connection.read(key: Key.intelInhibit), value != 0 { return true }
        return false
    }
}
