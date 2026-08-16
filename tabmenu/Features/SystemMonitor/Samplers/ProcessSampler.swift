//
//  ProcessSampler.swift
//  tabmenu
//

import Foundation
import os

nonisolated struct ProcessUsage: Sendable, Identifiable, Equatable {
    let id: Int32
    let name: String
    /// Percentage of a single core, as reported by `ps`.
    let cpuPercent: Double
    let memoryPercent: Double
}

/// Lists the heaviest processes. `ps` is used instead of per-process Mach calls because
/// sampling every task individually is far more expensive for a menu bar app.
/// Must stay off the main actor: spawning a process blocks its caller.
nonisolated final class ProcessSampler {
    private let logger = Logger(subsystem: "com.tabmenu", category: "ProcessSampler")

    func sample(limit: Int = 5) -> [ProcessUsage] {
        guard let output = runProcessListing() else { return [] }

        return output
            .split(separator: "\n")
            .dropFirst() // header
            .prefix(limit)
            .compactMap(parse)
    }

    private func parse(_ line: Substring) -> ProcessUsage? {
        let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard fields.count >= 4,
              let pid = Int32(fields[0]),
              let cpu = Double(fields[1]),
              let memory = Double(fields[2])
        else { return nil }

        let name = fields[3].trimmingCharacters(in: .whitespaces)
        return ProcessUsage(
            id: pid,
            name: URL(fileURLWithPath: name).lastPathComponent,
            cpuPercent: cpu,
            memoryPercent: memory
        )
    }

    private func runProcessListing() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid,pcpu,pmem,comm", "-r"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            logger.error("Failed to list processes: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
