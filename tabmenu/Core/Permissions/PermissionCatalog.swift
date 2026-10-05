//
//  PermissionCatalog.swift
//  tabmenu
//

import AVFoundation
import AppKit
import EventKit
import Observation
import os

/// Everything tabmenu can ask the system for, with live status for the onboarding flow.
enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case calendar
    case camera
    case automation

    var id: String { rawValue }

    /// Names match what macOS calls each permission in System Settings, so they are worth
    /// translating to the same wording the system uses.
    var title: String {
        switch self {
        case .accessibility: String(localized: "Accessibility", comment: "macOS permission name")
        case .screenRecording: String(localized: "Screen Recording", comment: "macOS permission name")
        case .calendar: String(localized: "Calendar", comment: "macOS permission name")
        case .camera: String(localized: "Camera", comment: "macOS permission name")
        case .automation: String(localized: "Music & Browsers", comment: "Automation permission, named by what it covers")
        }
    }

    var summary: String {
        switch self {
        case .accessibility:
            String(localized: "Move and switch windows, list them for previews, and paste for you.",
                   comment: "What Accessibility permission unlocks")
        case .screenRecording:
            String(localized: "Capture window thumbnails for Dock previews, and the artwork of hidden menu bar items.",
                   comment: "What Screen Recording permission unlocks")
        case .calendar:
            String(localized: "Show your next meeting in the notch, with a button to join it.",
                   comment: "What Calendar permission unlocks")
        case .camera:
            String(localized: "Power the Mirror tab in the notch panel.",
                   comment: "What Camera permission unlocks")
        case .automation:
            String(localized: "Read what Music, Spotify or your browser is playing.",
                   comment: "What Automation permission unlocks")
        }
    }

    var symbolName: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.on.rectangle"
        case .calendar: "calendar"
        case .camera: "video"
        case .automation: "music.note"
        }
    }

    /// Without Accessibility most of the app cannot work at all.
    var isRequired: Bool { self == .accessibility }

    /// Features degrade gracefully without these, which is worth saying out loud.
    var fallbackNote: String? {
        switch self {
        case .accessibility:
            nil
        case .screenRecording:
            String(localized: "Previews fall back to app icons.", comment: "What happens without Screen Recording")
        case .calendar:
            String(localized: "The Agenda tab stays empty.", comment: "What happens without Calendar access")
        case .camera:
            String(localized: "The Mirror tab stays empty.", comment: "What happens without Camera access")
        case .automation:
            String(localized: "Playback controls still work; only track details are missing.",
                   comment: "What happens without Automation access")
        }
    }

    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .calendar: anchor = "Privacy_Calendars"
        case .camera: anchor = "Privacy_Camera"
        case .automation: anchor = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

enum PermissionState: Equatable {
    case granted
    case denied
    /// Not yet decided, or a permission macOS only resolves on first use.
    case undetermined

    var isGranted: Bool { self == .granted }
}

/// Polls every permission so onboarding reflects changes made in System Settings while the
/// window is open.
@Observable
@MainActor
final class PermissionCatalog {
    private(set) var states: [PermissionKind: PermissionState] = [:]

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Permissions")
    @ObservationIgnored private let accessibility: AccessibilityPermission
    @ObservationIgnored private let screenRecording: ScreenRecordingPermission
    /// Held for the object's lifetime: a store that deallocates before its callback runs
    /// cancels the request, and the system prompt never appears.
    @ObservationIgnored private let eventStore = EKEventStore()
    @ObservationIgnored private var pollingTimer: Timer?

    init(
        accessibility: AccessibilityPermission? = nil,
        screenRecording: ScreenRecordingPermission? = nil
    ) {
        self.accessibility = accessibility ?? .shared
        self.screenRecording = screenRecording ?? .shared
        refresh()
    }

    func state(for kind: PermissionKind) -> PermissionState {
        states[kind] ?? .undetermined
    }

    /// Everything the app cannot work without has been granted.
    var isReady: Bool {
        PermissionKind.allCases
            .filter(\.isRequired)
            .allSatisfy { state(for: $0).isGranted }
    }

    func startPolling() {
        guard pollingTimer == nil else { return }
        refresh()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func refresh() {
        states[.accessibility] = accessibility.isTrusted ? .granted : .denied
        states[.screenRecording] = screenRecording.isGranted ? .granted : .denied
        states[.calendar] = calendarState()
        states[.camera] = cameraState()
        // macOS only decides Automation on first use, per target app, so there is nothing
        // meaningful to read ahead of time.
        states[.automation] = .undetermined
    }

    func request(_ kind: PermissionKind) {
        // A background app gets no permission prompt, so make sure tabmenu is frontmost first.
        NSApp.activate(ignoringOtherApps: true)
        logger.notice("requesting \(kind.rawValue, privacy: .public)")

        switch kind {
        case .accessibility:
            accessibility.request()
        case .screenRecording:
            screenRecording.request()
        case .calendar:
            requestCalendar()
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    self?.logger.notice("camera access granted=\(granted)")
                    self?.refresh()
                }
            }
        case .automation:
            openSettings(for: kind)
        }
    }

    func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Individual checks

    private func calendarState() -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    private func cameraState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    private func requestCalendar() {
        eventStore.requestFullAccessToEvents { granted, error in
            Task { @MainActor [weak self] in
                self?.logger.notice(
                    "calendar access granted=\(granted) error=\(error?.localizedDescription ?? "none", privacy: .public)"
                )
                self?.refresh()
            }
        }
    }
}
