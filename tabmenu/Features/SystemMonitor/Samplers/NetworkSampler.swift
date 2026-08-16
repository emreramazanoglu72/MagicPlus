//
//  NetworkSampler.swift
//  tabmenu
//

import Darwin
import Foundation

nonisolated struct NetworkThroughput: Sendable, Equatable {
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    var totalReceived: UInt64 = 0
    var totalSent: UInt64 = 0
}

/// Aggregates byte counters of all physical interfaces and turns them into a rate.
nonisolated final class NetworkSampler {
    private var previousReceived: UInt64 = 0
    private var previousSent: UInt64 = 0
    private var previousTimestamp: TimeInterval = 0

    func sample() -> NetworkThroughput {
        let (received, sent) = readCounters()
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            previousReceived = received
            previousSent = sent
            previousTimestamp = now
        }

        let elapsed = now - previousTimestamp
        guard previousTimestamp > 0, elapsed > 0 else {
            return NetworkThroughput(totalReceived: received, totalSent: sent)
        }

        // The per-interface counters are 32-bit and wrap at 4 GiB, and interfaces can vanish,
        // so the aggregate may shrink. Treat that tick as idle instead of underflowing; the
        // deferred resync makes the next tick measure from the new baseline.
        let receivedDelta = received >= previousReceived ? received - previousReceived : 0
        let sentDelta = sent >= previousSent ? sent - previousSent : 0

        return NetworkThroughput(
            downloadBytesPerSecond: Double(receivedDelta) / elapsed,
            uploadBytesPerSecond: Double(sentDelta) / elapsed,
            totalReceived: received,
            totalSent: sent
        )
    }

    private func readCounters() -> (received: UInt64, sent: UInt64) {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return (0, 0) }
        defer { freeifaddrs(addressList) }

        var received: UInt64 = 0
        var sent: UInt64 = 0

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let dataPointer = interface.ifa_data
            else { continue }

            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("lo") else { continue }

            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(data.ifi_ibytes)
            sent += UInt64(data.ifi_obytes)
        }

        return (received, sent)
    }
}
