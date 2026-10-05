//
//  HelperService.swift
//  MagicPlusHelper
//

import Foundation
import os

/// The privileged side of charge limiting.
///
/// It holds no policy of its own: the app decides what the target is and when it has been
/// reached, and this process only carries out the hardware change and guarantees it can be
/// undone. The watchdog is the point of the design — if the app stops talking, charging goes
/// back to normal on its own.
final class HelperService: NSObject, HelperProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: HelperConstants.machServiceName, category: "Helper")
    /// Every hardware access and every piece of state is serialised onto this queue.
    private let queue = DispatchQueue(label: "\(HelperConstants.machServiceName).work")
    private let control: ChargeControl?

    private var lastHeartbeat = Date()
    private var hasChangedHardware = false
    private var watchdog: DispatchSourceTimer?

    override init() {
        control = ChargeControl()
        super.init()

        // Anything an earlier run left behind is undone before this one accepts a request.
        control?.restoreDefaults()
        startWatchdog()
    }

    // MARK: - HelperProtocol

    func version(reply: @escaping (Int) -> Void) {
        reply(HelperConstants.version)
    }

    func chargeControlMechanism(reply: @escaping (String) -> Void) {
        queue.async { [control] in
            reply((control?.mechanism ?? .unsupported).rawValue)
        }
    }

    func setChargingInhibited(_ inhibited: Bool, reply: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, let control = self.control else { return reply(false) }
            self.lastHeartbeat = Date()
            let didApply = control.setChargingInhibited(inhibited)
            if didApply, inhibited { self.hasChangedHardware = true }
            self.logger.notice(
                "charging inhibited=\(inhibited, privacy: .public) applied=\(didApply, privacy: .public)"
            )
            reply(didApply)
        }
    }

    func setFirmwareChargeLimit(_ percentage: Int, reply: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, let control = self.control else { return reply(false) }
            self.lastHeartbeat = Date()
            let didApply = control.setFirmwareLimit(percentage: percentage)
            if didApply, percentage < 100 { self.hasChangedHardware = true }
            self.logger.notice(
                "firmware limit=\(percentage, privacy: .public) applied=\(didApply, privacy: .public)"
            )
            reply(didApply)
        }
    }

    func restoreDefaults(reply: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return reply(false) }
            self.lastHeartbeat = Date()
            self.restore()
            reply(true)
        }
    }

    func heartbeat(reply: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            self?.lastHeartbeat = Date()
            reply(true)
        }
    }

    // MARK: - Safety

    /// Undoes every hardware change. Safe to call when nothing was changed, and safe to call
    /// from a signal handler's queue, which is why it takes no arguments and answers nothing.
    func restore() {
        control?.restoreDefaults()
        hasChangedHardware = false
    }

    /// Restores charging if the app has gone quiet. Only armed once something was actually
    /// changed, so an idle helper does no hardware access at all.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.hasChangedHardware else { return }
            guard Date().timeIntervalSince(self.lastHeartbeat) > HelperConstants.watchdogTimeout else { return }
            self.logger.error("no heartbeat, restoring charging")
            self.restore()
        }
        timer.resume()
        watchdog = timer
    }
}
