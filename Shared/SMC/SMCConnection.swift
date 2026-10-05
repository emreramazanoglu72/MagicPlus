//
//  SMCConnection.swift
//  tabmenu
//

import Foundation
import IOKit

/// Talks to the System Management Controller through its IOKit user client.
///
/// The SMC protocol is in no header Apple ships. The struct below, the selector and the
/// command numbers are the layout every SMC tool on macOS has used since 2006, and it is
/// unchanged on Apple Silicon. Reading a key needs no privileges; writing one needs root,
/// which is why every write goes through the privileged helper instead of this type.
///
/// Nothing here assumes a particular Mac: the key list is read from the machine itself, so a
/// model with different sensors reports different sensors rather than nothing at all.
nonisolated final class SMCConnection {
    private let connection: io_connect_t

    /// `kSMCHandleYPCEvent`, the only selector the user client exposes.
    private static let selector: UInt32 = 2

    private enum Command: UInt8 {
        case readBytes = 5
        case writeBytes = 6
        case readIndex = 8
        case readKeyInfo = 9
    }

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    // MARK: - Keys

    /// How many keys this Mac's SMC holds.
    func keyCount() -> Int {
        guard let value = read(key: "#KEY") else { return 0 }
        return Int(value)
    }

    /// The key at a position in the SMC's own index, which is the only way to find out what
    /// a machine actually has.
    func key(at index: Int) -> String? {
        var input = SMCParameters()
        input.data8 = Command.readIndex.rawValue
        input.data32 = UInt32(index)
        guard let output = call(input), output.key != 0 else { return nil }
        return Self.string(from: output.key)
    }

    /// Every key the machine reports, in index order.
    func allKeys() -> [String] {
        (0..<keyCount()).compactMap { key(at: $0) }
    }

    // MARK: - Values

    /// Reads a key and converts it to a number, whatever fixed-point or float encoding the
    /// SMC chose for it. Returns nil for keys this Mac does not have, and for the handful of
    /// types that are not numeric at all.
    func read(key: String) -> Double? {
        guard let info = keyInfo(key) else { return nil }

        var input = SMCParameters()
        input.key = Self.code(key)
        input.keyInfo.dataSize = info.size
        input.data8 = Command.readBytes.rawValue

        guard let output = call(input) else { return nil }
        var bytes = output.bytes
        let raw = withUnsafeBytes(of: &bytes) { Array($0.prefix(Int(info.size))) }
        return Self.decode(raw, type: info.type)
    }

    /// Whether this Mac's SMC carries the key at all, which is how support for a feature is
    /// decided rather than by guessing from the model identifier.
    func exists(key: String) -> Bool {
        keyInfo(key) != nil
    }

    /// Writes a key. Only root may do this — an unprivileged process gets a refusal from the
    /// SMC itself — which is why the app calls this through its helper.
    @discardableResult
    func write(key: String, bytes: [UInt8]) -> Bool {
        guard let info = keyInfo(key), Int(info.size) == bytes.count else { return false }

        var input = SMCParameters()
        input.key = Self.code(key)
        input.keyInfo.dataSize = info.size
        input.data8 = Command.writeBytes.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (offset, byte) in bytes.enumerated() where offset < buffer.count {
                buffer[offset] = byte
            }
        }

        return call(input) != nil
    }

    private func keyInfo(_ key: String) -> (size: UInt32, type: String)? {
        var input = SMCParameters()
        input.key = Self.code(key)
        input.data8 = Command.readKeyInfo.rawValue

        guard let output = call(input), output.keyInfo.dataSize > 0 else { return nil }
        return (output.keyInfo.dataSize, Self.string(from: output.keyInfo.dataType))
    }

    private func call(_ parameters: SMCParameters) -> SMCParameters? {
        var input = parameters
        var output = SMCParameters()
        var outputSize = MemoryLayout<SMCParameters>.stride

        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    Self.selector,
                    inputPointer,
                    MemoryLayout<SMCParameters>.stride,
                    outputPointer,
                    &outputSize
                )
            }
        }

        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    // MARK: - Encoding

    /// Keys are four-character codes packed into a word, big end first.
    static func code(_ key: String) -> UInt32 {
        key.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
    }

    static func string(from code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// SMC values come back as floats, plain integers, or fixed-point numbers whose type
    /// name carries the layout: the last character of `sp78` or `fpe2` is the number of
    /// fraction bits, and the first two say whether it is signed.
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        guard !bytes.isEmpty else { return nil }

        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "ui8 ", "ui16", "ui32", "ui64":
            return Double(unsignedInteger(bytes))
        case "si8 ", "si16":
            return Double(signedInteger(bytes))
        default:
            guard type.count == 4, type.hasPrefix("sp") || type.hasPrefix("fp") else { return nil }
            guard let fractionBits = type.last.flatMap({ $0.hexDigitValue }) else { return nil }
            let scale = Double(1 << fractionBits)
            return type.hasPrefix("sp")
                ? Double(signedInteger(bytes)) / scale
                : Double(unsignedInteger(bytes)) / scale
        }
    }

    private static func unsignedInteger(_ bytes: [UInt8]) -> UInt64 {
        bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func signedInteger(_ bytes: [UInt8]) -> Int64 {
        let magnitude = unsignedInteger(bytes)
        let bits = min(bytes.count, 8) * 8
        let signBit = UInt64(1) << (bits - 1)
        guard magnitude & signBit != 0 else { return Int64(magnitude) }
        return Int64(bitPattern: magnitude | ~((UInt64(1) << bits) - 1))
    }
}

// MARK: - Wire format

/// The 80-byte structure the SMC user client takes and returns. Field order and padding are
/// load-bearing: `SMCParametersTests` pins the size so a change here cannot pass unnoticed.
nonisolated struct SMCParameters {
    var key: UInt32 = 0
    var version = SMCVersion()
    var powerLimits = SMCPowerLimits()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8,
        UInt8
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

nonisolated struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

nonisolated struct SMCPowerLimits {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPowerLimit: UInt32 = 0
    var gpuPowerLimit: UInt32 = 0
    var memoryPowerLimit: UInt32 = 0
}

nonisolated struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    /// C pads a struct out to a multiple of its own alignment when it is a member of another
    /// one; Swift places the next field straight after the last byte instead. Without these
    /// three bytes spelled out, everything after `keyInfo` lands early, the block comes to 76
    /// bytes instead of 80, and every single SMC read comes back empty.
    private var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}
