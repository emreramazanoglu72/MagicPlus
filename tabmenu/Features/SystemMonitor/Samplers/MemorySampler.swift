//
//  MemorySampler.swift
//  tabmenu
//

import Darwin
import Foundation

nonisolated struct MemoryUsage: Sendable, Equatable {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0

    /// Matches Activity Monitor's "Memory Used".
    var used: UInt64 { app + wired + compressed }

    var pressure: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

/// Samples virtual memory statistics from the Mach host.
nonisolated final class MemorySampler {
    private let pageSize: UInt64
    private let totalMemory: UInt64

    init() {
        var size = vm_size_t()
        host_page_size(mach_host_self(), &size)
        pageSize = UInt64(size)
        totalMemory = ProcessInfo.processInfo.physicalMemory
    }

    func sample() -> MemoryUsage {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryUsage(total: totalMemory) }

        let purgeable = UInt64(statistics.purgeable_count) * pageSize
        let internalPages = UInt64(statistics.internal_page_count) * pageSize
        let externalPages = UInt64(statistics.external_page_count) * pageSize

        return MemoryUsage(
            total: totalMemory,
            app: internalPages > purgeable ? internalPages - purgeable : 0,
            wired: UInt64(statistics.wire_count) * pageSize,
            compressed: UInt64(statistics.compressor_page_count) * pageSize,
            cached: externalPages + purgeable
        )
    }
}
