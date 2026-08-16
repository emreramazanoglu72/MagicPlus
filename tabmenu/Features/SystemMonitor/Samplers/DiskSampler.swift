//
//  DiskSampler.swift
//  tabmenu
//

import Foundation
import IOKit

nonisolated struct DiskUsage: Sendable, Equatable {
    var total: Int64 = 0
    var free: Int64 = 0
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0

    var used: Int64 { max(0, total - free) }

    var ratio: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

/// Combines boot volume capacity with aggregated block storage throughput.
nonisolated final class DiskSampler {
    /// Registry keys from `IOKit/storage/IOBlockStorageDriver.h`; the C macros are not
    /// exposed to Swift, so their literal values are used.
    private enum RegistryKey {
        static let statistics = "Statistics"
        static let bytesRead = "Bytes (Read)"
        static let bytesWritten = "Bytes (Write)"
    }

    private var previousRead: UInt64 = 0
    private var previousWritten: UInt64 = 0
    private var previousTimestamp: TimeInterval = 0

    func sample() -> DiskUsage {
        var usage = capacity()
        let (read, written) = readThroughputCounters()
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            previousRead = read
            previousWritten = written
            previousTimestamp = now
        }

        let elapsed = now - previousTimestamp
        guard previousTimestamp > 0, elapsed > 0 else { return usage }

        // A detached drive drops its counters out of the aggregate, so the totals can shrink.
        // Treat that tick as idle instead of underflowing; the deferred resync makes the next
        // tick measure from the new baseline.
        let readDelta = read >= previousRead ? read - previousRead : 0
        let writtenDelta = written >= previousWritten ? written - previousWritten : 0
        usage.readBytesPerSecond = Double(readDelta) / elapsed
        usage.writeBytesPerSecond = Double(writtenDelta) / elapsed
        return usage
    }

    private func capacity() -> DiskUsage {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return DiskUsage() }

        return DiskUsage(
            total: Int64(values.volumeTotalCapacity ?? 0),
            free: values.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }

    private func readThroughputCounters() -> (read: UInt64, written: UInt64) {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0

        while case let drive = IOIteratorNext(iterator), drive != 0 {
            defer { IOObjectRelease(drive) }
            guard let properties = IORegistryEntryCreateCFProperty(
                drive,
                RegistryKey.statistics as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            read += (properties[RegistryKey.bytesRead] as? NSNumber)?.uint64Value ?? 0
            written += (properties[RegistryKey.bytesWritten] as? NSNumber)?.uint64Value ?? 0
        }

        return (read, written)
    }
}
