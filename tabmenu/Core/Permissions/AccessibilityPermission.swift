//
//  AccessibilityPermission.swift
//  tabmenu
//

import AppKit
import ApplicationServices
import Observation

/// Tracks the Accessibility trust state, which window management and auto-paste both depend on.
/// macOS offers no change notification for it, so the state is polled while the app is running.
@Observable
@MainActor
final class AccessibilityPermission {
    static let shared = AccessibilityPermission()

    private(set) var isTrusted: Bool
    @ObservationIgnored private var pollingTimer: Timer?

    private init() {
        isTrusted = AXIsProcessTrusted()
        startPolling()
    }

    func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func refresh() {
        let current = AXIsProcessTrusted()
        if current != isTrusted { isTrusted = current }
    }

    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
