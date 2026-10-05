//
//  ChargeLimitService.swift
//  tabmenu
//

import Foundation
import Observation
import os

/// When charging should be held back, given where the battery is now.
///
/// Pulled out of the service so the one rule that matters can be reasoned about on its own:
/// a battery resting exactly on its target must not switch charging on and off every tick,
/// which is worse for the cells than the charge it is avoiding.
nonisolated enum ChargeLimitPolicy {
    static func shouldInhibit(level: Double, target: Double, hysteresis: Double, isInhibited: Bool) -> Bool {
        if level >= target { return true }
        if level <= target - hysteresis { return false }
        // Inside the band: whatever the hardware is already doing is right.
        return isInhibited
    }
}

/// Holds the battery at a level of the user's choosing instead of at 100%.
///
/// The app owns the policy and the helper owns the hardware: this service watches the charge
/// level and asks the helper to switch charging off when the target is reached and on again
/// when it drops below it. Two rules keep it honest — the limit only holds while MagicPlus is
/// running, and every path out of the app puts charging back to normal.
@Observable
@MainActor
final class ChargeLimitService {
    /// What this Mac is capable of, probed from the SMC without any privileges, so the UI can
    /// say whether the feature is worth installing a helper for.
    private(set) var mechanism: ChargeControlMechanism = .unsupported
    /// True while charging is actually being held back.
    private(set) var isHoldingCharge = false
    private(set) var battery = BatteryCondition()
    private(set) var lastFailure: String?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let installer: HelperInstaller
    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "ChargeLimit")
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    /// What the hardware was last told, so a tick that changes nothing sends nothing.
    @ObservationIgnored private var appliedInhibit: Bool?
    @ObservationIgnored private var appliedFirmwareLimit: Int?

    /// The level is allowed to fall this far below the target before charging resumes.
    /// Without it a battery resting exactly on the target would switch charging on and off
    /// every tick, which is worse for the cells than the charge it is trying to avoid.
    private static let hysteresis = 0.05
    private static let interval: TimeInterval = 30

    init(preferences: Preferences, installer: HelperInstaller) {
        self.preferences = preferences
        self.installer = installer
    }

    var isEnabled: Bool { preferences.isChargeLimitEnabled }
    var targetPercentage: Int { preferences.chargeLimitPercentage }
    var isSupported: Bool { mechanism != .unsupported }

    // MARK: - Lifecycle

    func start() {
        mechanism = ChargeControl()?.mechanism ?? .unsupported
        installer.refreshState()
        updateConfiguration()
    }

    /// Re-reads every preference this depends on. Called at launch and on every edit.
    func updateConfiguration() {
        appliedInhibit = nil
        appliedFirmwareLimit = nil
        restartTimer()
        schedule()
    }

    /// Switches charging back on and drops the timer. Called when the feature is turned off
    /// and when the app is on its way out.
    func shutDown() {
        timer?.invalidate()
        timer = nil
        applyTask?.cancel()
        applyTask = nil
        // Anything that was applied has to come off, including a firmware ceiling that is not
        // "holding" anything at this moment but would still outlive the app.
        guard isHoldingCharge || appliedInhibit == true || appliedFirmwareLimit != nil else { return }
        installer.restoreSynchronously()
        isHoldingCharge = false
        appliedInhibit = nil
        appliedFirmwareLimit = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard preferences.isChargeLimitEnabled, installer.state.isInstalled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    private func schedule() {
        guard applyTask == nil else { return }
        applyTask = Task { [weak self] in
            await self?.apply()
            self?.applyTask = nil
        }
    }

    // MARK: - Policy

    private func apply() async {
        guard installer.state.isInstalled else {
            isHoldingCharge = false
            return
        }

        // Tells the helper's watchdog the app is still here. A helper that stops hearing this
        // restores charging on its own.
        _ = await installer.call(fallback: false) { helper, reply in helper.heartbeat(reply: reply) }

        guard preferences.isChargeLimitEnabled else {
            await restore()
            return
        }

        let status = await Task.detached { BatterySampler().sample() }.value
        battery = status
        guard status.isPresent else { return }

        switch mechanism {
        case .firmwareLimit:
            await applyFirmwareLimit()
        case .chargingSwitch:
            await applyChargingSwitch(level: status.percentage)
        case .unsupported:
            break
        }
    }

    /// Macs that keep the ceiling themselves are told once and left to it. The value is only
    /// written when it changes: the heartbeat already keeps the watchdog from undoing it, so
    /// re-asserting every tick would be pure hardware writes for nothing.
    private func applyFirmwareLimit() async {
        let target = preferences.chargeLimitPercentage
        guard target != appliedFirmwareLimit else { return }

        let didApply = await installer.call(fallback: false) { helper, reply in
            helper.setFirmwareChargeLimit(target, reply: reply)
        }
        record(didApply: didApply, holding: didApply)
        if didApply { appliedFirmwareLimit = target }
    }

    private func applyChargingSwitch(level: Double) async {
        let shouldInhibit = ChargeLimitPolicy.shouldInhibit(
            level: level,
            target: Double(preferences.chargeLimitPercentage) / 100,
            hysteresis: Self.hysteresis,
            isInhibited: appliedInhibit ?? false
        )

        guard shouldInhibit != appliedInhibit else { return }
        let didApply = await installer.call(fallback: false) { helper, reply in
            helper.setChargingInhibited(shouldInhibit, reply: reply)
        }
        record(didApply: didApply, holding: didApply && shouldInhibit)
        if didApply { appliedInhibit = shouldInhibit }
    }

    private func restore() async {
        guard appliedInhibit != false || isHoldingCharge else { return }
        _ = await installer.call(fallback: false) { helper, reply in helper.restoreDefaults(reply: reply) }
        appliedInhibit = false
        appliedFirmwareLimit = nil
        isHoldingCharge = false
    }

    private func record(didApply: Bool, holding: Bool) {
        isHoldingCharge = holding
        if didApply {
            lastFailure = nil
        } else {
            logger.error("the SMC refused the charge control write")
            lastFailure = String(
                localized: "This Mac refused the charging change.",
                comment: "Charge limit could not be applied"
            )
        }
    }
}
