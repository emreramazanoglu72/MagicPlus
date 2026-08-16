//
//  MediaKeySender.swift
//  tabmenu
//

import AppKit
import ApplicationServices
import os

/// Posts the hardware media keys.
///
/// macOS routes these to whichever app currently owns the media session — browsers included
/// — so a YouTube tab responds just like a native player. This is deliberately used instead
/// of MediaRemote: that private framework now returns nothing without a special entitlement.
@MainActor
enum MediaKeySender {
    // From IOKit's `ev_keymap.h`, which is not bridged into Swift.
    private static let playPauseKey: Int32 = 16
    private static let nextKey: Int32 = 19
    private static let previousKey: Int32 = 20

    private static let logger = Logger(subsystem: "com.tabmenu", category: "MediaKeys")

    @discardableResult
    static func playPause() -> Bool { post(playPauseKey) }
    @discardableResult
    static func nextTrack() -> Bool { post(nextKey) }
    @discardableResult
    static func previousTrack() -> Bool { post(previousKey) }

    @discardableResult
    private static func post(_ key: Int32) -> Bool {
        guard AXIsProcessTrusted() else {
            logger.error("media key \(key) dropped: no Accessibility permission")
            return false
        }

        var delivered = 0
        for isKeyDown in [true, false] {
            let state = isKeyDown ? 0x0A : 0x0B
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | Int32(state << 8)),
                data2: -1
            ), let cgEvent = event.cgEvent else { continue }

            cgEvent.post(tap: .cghidEventTap)
            delivered += 1
        }

        logger.notice("media key \(key) delivered \(delivered)/2 events")
        return delivered == 2
    }
}
