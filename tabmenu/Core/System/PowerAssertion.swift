//
//  PowerAssertion.swift
//  tabmenu
//

import IOKit.pwr_mgt
import os

/// Idle behaviours an assertion holds off, one case per `caffeinate` flag. The IOKit API is
/// used directly rather than spawning `caffeinate`, so there is no helper process to outlive
/// the app or to leak if it is force quit.
enum PowerAssertionKind: String, CaseIterable, Sendable {
    /// `caffeinate -d`. Keeps the display on, which also holds off the screen saver and the
    /// lock screen that follows it.
    case displaySleep
    /// `caffeinate -i`. Stops the system sleeping once the idle timer elapses.
    case idleSystemSleep
    /// `caffeinate -m`. Stops idle disks spinning down.
    case diskIdle
    /// `caffeinate -s`. Stops the system sleeping at all while on AC power.
    case systemSleep

    fileprivate var assertionType: String {
        switch self {
        case .displaySleep: kIOPMAssertPreventUserIdleDisplaySleep
        case .idleSystemSleep: kIOPMAssertPreventUserIdleSystemSleep
        case .diskIdle: kIOPMAssertPreventDiskIdle
        case .systemSleep: kIOPMAssertionTypePreventSystemSleep
        }
    }
}

/// Holds IOKit power assertions for as long as the instance lives; releasing it lets the Mac
/// idle again. Assertions are owned by the process, so quitting or crashing always clears them.
final class PowerAssertion {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "PowerAssertion")

    private var identifiers: [IOPMAssertionID] = []

    /// Fails when the system refused every assertion, so callers never advertise a state the
    /// machine is not actually honouring.
    init?(kinds: [PowerAssertionKind], reason: String) {
        for kind in kinds {
            var identifier = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kind.assertionType as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &identifier
            )
            if result == kIOReturnSuccess {
                identifiers.append(identifier)
            } else {
                Self.logger.error(
                    "Assertion \(kind.rawValue, privacy: .public) refused: \(result, privacy: .public)"
                )
            }
        }

        guard !identifiers.isEmpty else { return nil }
    }

    deinit { release() }

    func release() {
        for identifier in identifiers {
            IOPMAssertionRelease(identifier)
        }
        identifiers.removeAll()
    }
}
