//
//  LoginItems.swift
//  MagicPlus
//

import Foundation
import os

/// Reading and editing the login items, for applications other than this one.
///
/// `SMAppService` manages the calling application's own login item and nothing else, which is
/// correct and also useless here: the Dock's "Open at Login" is about whatever app was
/// right-clicked. System Events is the scriptable route macOS offers for that, so it is the one
/// used — and it needs Automation permission, which the app already asks for.
///
/// Reading it costs an `osascript` subprocess and the better part of a second, so nothing here
/// reads it on the thread that asks. ``contains(_:)`` answers from the last reading and starts a
/// new one in the background if that reading has aged out. It has to work this way: SwiftUI builds
/// the context menu of every icon in the dock while it evaluates the strip's body, so the question
/// gets asked two dozen times inside a single layout pass. Answering it honestly each time froze
/// the application solid — a sample of the hang was two and a half seconds of one layout pass,
/// blocked in `read()` waiting for System Events.
nonisolated enum LoginItems {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "Dock")

    private static let lock = NSLock()
    private static var cached: Set<String> = []
    private static var readAt = Date.distantPast
    private static var isReading = false

    /// How long a reading stands for. Login items change about once a month; this only has to be
    /// short enough that the menu is right the second time somebody looks.
    private static let lifetime: TimeInterval = 30

    /// Whether an application opens at login, from the last reading. Never blocks.
    static func contains(_ name: String) -> Bool {
        refreshIfStale()
        let key = name.lowercased()
        return lock.withLock { cached.contains(key) }
    }

    /// Starts a reading if the last one has aged out. At most one is ever in flight, so a dock full
    /// of icons all asking at once produces one subprocess rather than one each.
    static func refreshIfStale() {
        let shouldRead: Bool = lock.withLock {
            guard !isReading, Date().timeIntervalSince(readAt) > lifetime else { return false }
            isReading = true
            return true
        }
        guard shouldRead else { return }

        DispatchQueue.global(qos: .utility).async {
            let names = Set(read().map { $0.lowercased() })
            lock.withLock {
                cached = names
                readAt = Date()
                isReading = false
            }
        }
    }

    /// Throws the last reading away, for when this app is what changed the list.
    static func invalidate() {
        lock.withLock { readAt = .distantPast }
        refreshIfStale()
    }

    private static func read() -> [String] {
        guard let output = run("tell application \"System Events\" to get the name of every login item")
        else { return [] }
        return output
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// - Important: Blocks until `osascript` exits. Only call it off the main thread, or from
    ///   something a click started — never from a view's body.
    @discardableResult
    static func run(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("login items: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
