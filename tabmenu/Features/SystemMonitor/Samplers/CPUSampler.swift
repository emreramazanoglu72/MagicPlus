//
//  CPUSampler.swift
//  tabmenu
//

import Darwin

nonisolated struct CPULoad: Sendable, Equatable {
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var cores: [Double] = []
}

/// Reads per-core tick counters from the Mach host and converts consecutive samples into load.
/// Sampling runs off the main actor, driven by `MetricsCollector`.
nonisolated final class CPUSampler {
    private var previousTicks: [[UInt32]] = []

    func sample() -> CPULoad {
        guard let ticks = readTicks() else { return CPULoad() }
        defer { previousTicks = ticks }

        guard previousTicks.count == ticks.count else { return CPULoad() }

        var cores: [Double] = []
        var totalUsed = 0.0
        var totalUser = 0.0
        var totalSystem = 0.0
        var totalTicks = 0.0

        for (index, current) in ticks.enumerated() {
            let previous = previousTicks[index]
            let user = Double(current[0] &- previous[0])
            let system = Double(current[1] &- previous[1])
            let idle = Double(current[2] &- previous[2])
            let nice = Double(current[3] &- previous[3])
            let total = user + system + idle + nice

            cores.append(total > 0 ? (user + system + nice) / total : 0)
            totalUsed += user + system + nice
            totalUser += user + nice
            totalSystem += system
            totalTicks += total
        }

        guard totalTicks > 0 else { return CPULoad(cores: cores) }
        return CPULoad(
            total: totalUsed / totalTicks,
            user: totalUser / totalTicks,
            system: totalSystem / totalTicks,
            cores: cores
        )
    }

    /// Returns `[core][CPU_STATE_USER, SYSTEM, IDLE, NICE]`.
    private func readTicks() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stateCount = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { core in
            let base = core * stateCount
            return [
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ]
        }
    }
}
