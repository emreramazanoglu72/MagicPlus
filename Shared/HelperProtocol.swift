//
//  HelperProtocol.swift
//  MagicPlus
//

import Foundation

/// Names and limits both sides of the privileged connection have to agree on.
nonisolated enum HelperConstants {
    /// Bundle identifier of the app allowed to talk to the helper.
    static let applicationBundleIdentifier = "com.tabmenu"
    static let machServiceName = "com.tabmenu.helper"
    static let daemonPlistName = "com.tabmenu.helper.plist"

    /// Bumped whenever the protocol changes, so an app talking to a stale helper left behind
    /// by an older version notices and reinstalls instead of misbehaving.
    static let version = 1

    /// The helper undoes everything it has done if the app stops checking in for this long.
    /// Nothing it does may outlive the app that asked for it — a Mac left refusing to charge
    /// because an app crashed is the failure mode worth engineering against.
    static let watchdogTimeout: TimeInterval = 30
}

/// Everything the helper is willing to do with root privileges.
///
/// Deliberately narrow: there is no "write this SMC key" call, because a privileged process
/// that writes any key on request is an escalation tool wearing a helper's coat. Every method
/// here is one specific, reversible hardware change.
@objc protocol HelperProtocol {
    nonisolated func version(reply: @escaping (Int) -> Void)

    /// Which charge control mechanism this Mac has, as a `ChargeControlMechanism` raw value.
    nonisolated func chargeControlMechanism(reply: @escaping (String) -> Void)

    /// Switches charging off or on. Answers with whether the hardware took the change.
    nonisolated func setChargingInhibited(_ inhibited: Bool, reply: @escaping (Bool) -> Void)

    /// Hands a maximum charge level to the firmware, on the Macs that keep one themselves.
    nonisolated func setFirmwareChargeLimit(_ percentage: Int, reply: @escaping (Bool) -> Void)

    /// Puts charging back to normal. Called when the limit is switched off, when the app
    /// quits, and by the watchdog.
    nonisolated func restoreDefaults(reply: @escaping (Bool) -> Void)

    /// Tells the helper the app is still there. Missing heartbeats trip the watchdog.
    nonisolated func heartbeat(reply: @escaping (Bool) -> Void)
}
