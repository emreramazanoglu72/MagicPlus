//
//  ExternalDisplayBrightness.swift
//  MagicPlus
//

import AppKit
import IOKit
import Observation
import os

/// DDC/CI brightness control for external displays on Apple Silicon.
///
/// The transport is IOAVService — exported from IOKit but not in the public headers, so the
/// functions are resolved with `dlsym` and the whole feature degrades to "not supported"
/// when the OS stops exporting them. Packets follow the DDC/CI spec: VCP code 0x10 to the
/// display's 0x37 I2C address.
///
/// Note for distribution: this is fine for the notarized direct-download build, but it is
/// an automatic App Store rejection — remove this file first if a MAS build ever happens.
nonisolated enum DDC {
    private typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias TransferI2C = @convention(c) (AnyObject?, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn

    private static let logger = Logger(subsystem: "com.tabmenu", category: "DDC")

    private static let bindings: (create: CreateWithService, write: TransferI2C, read: TransferI2C)? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let write = dlsym(handle, "IOAVServiceWriteI2C"),
              let read = dlsym(handle, "IOAVServiceReadI2C")
        else { return nil }
        return (
            unsafeBitCast(create, to: CreateWithService.self),
            unsafeBitCast(write, to: TransferI2C.self),
            unsafeBitCast(read, to: TransferI2C.self)
        )
    }()

    static var isSupported: Bool { bindings != nil }

    // MARK: - Discovery

    /// AV services of externally connected displays, in registry order.
    static func externalServices() -> [AnyObject] {
        guard let bindings else { return [] }

        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [AnyObject] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else { continue }
            if let service = bindings.create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                services.append(service)
            }
        }
        return services
    }

    // MARK: - Brightness

    @discardableResult
    static func writeBrightness(_ percent: Int, to service: AnyObject) -> Bool {
        guard let bindings else { return false }
        var packet = brightnessWritePacket(percent: percent)
        let status = bindings.write(service, 0x37, 0x51, &packet, UInt32(packet.count))
        if status != kIOReturnSuccess {
            logger.error("DDC write failed: \(status)")
            return false
        }
        return true
    }

    /// Asks the display for its current brightness. Many monitors answer unreliably, so a
    /// `nil` here just means "start the slider in the middle".
    static func readBrightness(from service: AnyObject) -> Int? {
        guard let bindings else { return nil }

        var request = brightnessReadPacket()
        guard bindings.write(service, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else {
            return nil
        }
        // The spec gives the display 40ms to prepare the reply.
        usleep(40_000)

        var reply = [UInt8](repeating: 0, count: 12)
        guard bindings.read(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess else {
            return nil
        }
        return parseBrightnessReply(reply)
    }

    // MARK: - Packets (pure, tested)

    /// Set VCP 0x10: [length|0x80, opcode, vcp, hi, lo, checksum].
    static func brightnessWritePacket(percent: Int) -> [UInt8] {
        let value = UInt16(min(max(percent, 0), 100))
        var packet: [UInt8] = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(checksum(packet))
        return packet
    }

    static func brightnessReadPacket() -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, 0x10]
        packet.append(checksum(packet))
        return packet
    }

    /// DDC checksums start from the destination/source pair the wire protocol prepends.
    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x6E ^ 0x51) { $0 ^ $1 }
    }

    /// VCP feature reply: max at bytes 6–7, current at 8–9.
    static func parseBrightnessReply(_ reply: [UInt8]) -> Int? {
        guard reply.count >= 10, reply[2] == 0x02 else { return nil }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        guard maximum > 0, current <= maximum else { return nil }
        return current * 100 / maximum
    }
}

// MARK: - Service

struct BrightnessDisplay: Identifiable, Equatable {
    let id: Int
    let name: String
    var percent: Double

    static func == (lhs: BrightnessDisplay, rhs: BrightnessDisplay) -> Bool {
        lhs.id == rhs.id && lhs.percent == rhs.percent
    }
}

/// Brightness sliders for whatever external displays are connected.
@Observable
@MainActor
final class DisplayBrightnessService {
    private(set) var displays: [BrightnessDisplay] = []

    @ObservationIgnored private var services: [AnyObject] = []
    /// Sliders fire continuously; writes are throttled so the display's I2C bus keeps up.
    @ObservationIgnored private var lastWrite: [Int: Date] = [:]
    @ObservationIgnored private var pendingFlush: [Int: Task<Void, Never>] = [:]

    private static let writeInterval: TimeInterval = 0.05

    var isSupported: Bool { DDC.isSupported }

    /// Re-enumerates displays; initial brightness is read once per new display.
    func refresh() {
        guard DDC.isSupported else { return }

        Task.detached(priority: .utility) {
            let services = DDC.externalServices()
            let names = await Self.displayNames(count: services.count)
            let readings = services.map { DDC.readBrightness(from: $0) }

            await MainActor.run {
                self.services = services
                self.displays = services.indices.map { index in
                    let existing = self.displays.first { $0.id == index }
                    return BrightnessDisplay(
                        id: index,
                        name: names[index],
                        percent: existing?.percent ?? readings[index].map { Double($0) / 100 } ?? 0.5
                    )
                }
            }
        }
    }

    func setBrightness(_ percent: Double, for display: BrightnessDisplay) {
        guard services.indices.contains(display.id) else { return }
        let clamped = min(max(percent, 0), 1)

        displays = displays.map {
            $0.id == display.id ? BrightnessDisplay(id: $0.id, name: $0.name, percent: clamped) : $0
        }

        let now = Date()
        if now.timeIntervalSince(lastWrite[display.id] ?? .distantPast) >= Self.writeInterval {
            // A pending trailing flush carries an older value; drop it so it cannot land last.
            pendingFlush[display.id]?.cancel()
            pendingFlush[display.id] = nil
            lastWrite[display.id] = now
            write(clamped, to: display.id)
        } else {
            scheduleTrailingWrite(clamped, for: display.id)
        }
    }

    private func write(_ percent: Double, to index: Int) {
        guard services.indices.contains(index) else { return }
        let service = services[index]
        Task.detached(priority: .userInitiated) {
            DDC.writeBrightness(Int((percent * 100).rounded()), to: service)
        }
    }

    /// The last slider position always lands, even when the throttle swallowed the stream.
    private func scheduleTrailingWrite(_ percent: Double, for index: Int) {
        pendingFlush[index]?.cancel()
        pendingFlush[index] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.lastWrite[index] = Date()
            self?.write(percent, to: index)
        }
    }

    /// Names from NSScreen when the count lines up; generic labels otherwise, because the
    /// registry order and screen order are not guaranteed to match.
    private static func displayNames(count: Int) async -> [String] {
        await MainActor.run {
            let externalScreens = NSScreen.screens.filter { screen in
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
                return CGDisplayIsBuiltin(id) == 0
            }
            if externalScreens.count == count {
                return externalScreens.map(\.localizedName)
            }
            return (1...max(count, 1)).map { index in
                String(localized: "External Display \(index)", comment: "Fallback name for a DDC display")
            }
        }
    }
}
