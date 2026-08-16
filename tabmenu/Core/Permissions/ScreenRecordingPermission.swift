//
//  ScreenRecordingPermission.swift
//  tabmenu
//

import AppKit
import CoreGraphics
import Observation

/// Screen Recording is required to capture window thumbnails. Like Accessibility, macOS
/// offers no change notification for it, so the state is polled while the app runs.
@Observable
@MainActor
final class ScreenRecordingPermission {
    static let shared = ScreenRecordingPermission()

    private(set) var isGranted: Bool
    @ObservationIgnored private var pollingTimer: Timer?

    private init() {
        isGranted = CGPreflightScreenCaptureAccess()
        startPolling()
    }

    /// Triggers the system prompt. macOS only shows it once per app version; afterwards the
    /// user has to enable it in System Settings.
    func request() {
        if CGRequestScreenCaptureAccess() {
            isGranted = true
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func refresh() {
        let current = CGPreflightScreenCaptureAccess()
        if current != isGranted { isGranted = current }
    }

    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
