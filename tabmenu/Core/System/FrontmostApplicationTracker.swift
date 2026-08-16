//
//  FrontmostApplicationTracker.swift
//  tabmenu
//

import AppKit
import os

/// Remembers which application the user was working in before one of tabmenu's surfaces
/// took focus. Every panel records it on open; window commands and auto-paste read it back.
@MainActor
final class FrontmostApplicationTracker {
    private let logger = Logger(subsystem: "com.tabmenu", category: "Frontmost")

    /// Held strongly: `NSWorkspace` hands back a fresh `NSRunningApplication` each time, so a
    /// weak reference would be gone before the value is ever read.
    private(set) var lastExternalApplication: NSRunningApplication?

    func remember() {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ownProcessIdentifier
        else {
            logger.notice("remember skipped, frontmost is tabmenu itself")
            return
        }
        lastExternalApplication = frontmost
        logger.notice("remembered \(frontmost.localizedName ?? "unknown", privacy: .public)")
    }

    /// Brings the remembered application back to the front.
    func restore() {
        guard let application = lastExternalApplication, !application.isTerminated else { return }
        application.activate()
    }
}
