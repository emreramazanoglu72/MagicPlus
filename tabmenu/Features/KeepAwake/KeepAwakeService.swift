//
//  KeepAwakeService.swift
//  tabmenu
//

import AppKit
import Foundation
import Observation
import os

/// Holds the Mac awake — no display sleep, no system sleep, no disk spin-down, and therefore
/// no idle lock screen. Equivalent to leaving `caffeinate -dims` running, with an optional
/// timer that switches it off again.
@Observable
@MainActor
final class KeepAwakeService {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "KeepAwake")
    private static let reason = "MagicPlus Keep Awake"

    private(set) var isActive = false

    /// Duration the running session was started with.
    private(set) var activeDuration: KeepAwakeDuration?

    /// Seconds left before the session ends by itself; `nil` while inactive or indefinite.
    private(set) var remaining: TimeInterval?

    private let preferences: Preferences

    /// Fired on wake when the system slept while a session was active — the lid, a forced
    /// sleep, or battery preservation, none of which an assertion can hold off.
    @ObservationIgnored var onSleepDespiteSession: (() -> Void)?

    @ObservationIgnored private var assertion: PowerAssertion?
    @ObservationIgnored private var sleptDuringSession = false
    @ObservationIgnored private var expiry: Date?
    @ObservationIgnored private var ticker: Timer?

    init(preferences: Preferences) {
        self.preferences = preferences

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isActive else { return }
                self.sleptDuringSession = true
                Self.logger.notice("system slept while keep awake was active")
            }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.sleptDuringSession else { return }
                self.sleptDuringSession = false
                self.onSleepDespiteSession?()
            }
        }
    }

    /// Duration the next session will run for: whichever was chosen last.
    var selectedDuration: KeepAwakeDuration {
        preferences.keepAwakeDuration
    }

    /// One-line status for tooltips and help tags while a session runs: the countdown left,
    /// or "until turned off" for an indefinite hold.
    var statusText: String {
        guard let remaining else {
            return String(localized: "Keep Awake on · until turned off",
                          comment: "Menu bar tooltip while keep-awake runs with no timer")
        }
        return String(localized: "Keep Awake on · \(Format.countdown(remaining)) left",
                      comment: "Menu bar tooltip while keep-awake runs; placeholder is a countdown like 1:04:09")
    }

    /// Restores the previous session when the user asked for it to survive relaunches.
    func start() {
        guard preferences.resumesKeepAwakeAtLaunch else { return }
        activate(for: preferences.keepAwakeDuration)
    }

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate(for: preferences.keepAwakeDuration)
        }
    }

    /// Starts a session, or re-arms a running one with a new duration. The chosen duration
    /// becomes the default for future sessions.
    func activate(for duration: KeepAwakeDuration) {
        preferences.keepAwakeDuration = duration
        engage(for: duration)
    }

    /// Arms a session without touching the stored duration preference — presentation mode
    /// needs an indefinite hold that does not overwrite the user's usual choice.
    func engage(for duration: KeepAwakeDuration) {
        releaseAssertion()

        guard let assertion = PowerAssertion(kinds: assertionKinds, reason: Self.reason) else {
            Self.logger.error("Could not hold any power assertion; leaving keep awake off")
            reset()
            return
        }

        self.assertion = assertion
        isActive = true
        activeDuration = duration
        schedule(seconds: duration.seconds)
    }

    func deactivate() {
        releaseAssertion()
        reset()
    }

    /// Re-applies the assertion set after the display option changes, so the switch takes
    /// effect without the user cycling the toggle.
    func reapplyOptions() {
        guard isActive, let duration = activeDuration else { return }
        let previousExpiry = expiry

        releaseAssertion()
        guard let assertion = PowerAssertion(kinds: assertionKinds, reason: Self.reason) else {
            reset()
            return
        }
        self.assertion = assertion
        activeDuration = duration
        schedule(seconds: previousExpiry.map { $0.timeIntervalSinceNow })
    }

    // MARK: - Assertions

    /// `caffeinate -dims`, minus the display flag when the user only wants sleep held off.
    private var assertionKinds: [PowerAssertionKind] {
        var kinds: [PowerAssertionKind] = [.idleSystemSleep, .diskIdle, .systemSleep]
        if preferences.keepsDisplayAwake {
            kinds.insert(.displaySleep, at: 0)
        }
        return kinds
    }

    private func releaseAssertion() {
        assertion?.release()
        assertion = nil
        ticker?.invalidate()
        ticker = nil
    }

    private func reset() {
        isActive = false
        activeDuration = nil
        remaining = nil
        expiry = nil
    }

    // MARK: - Countdown

    private func schedule(seconds: TimeInterval?) {
        guard let seconds else {
            expiry = nil
            remaining = nil
            return
        }

        guard seconds > 0 else {
            deactivate()
            return
        }

        expiry = Date(timeIntervalSinceNow: seconds)
        remaining = seconds
        // Ticks are only for the countdown label; expiry is decided against the wall clock so
        // a sleep or a missed fire cannot extend the session.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let expiry else { return }
        let left = expiry.timeIntervalSinceNow
        if left <= 0 {
            deactivate()
        } else {
            remaining = left
        }
    }
}
