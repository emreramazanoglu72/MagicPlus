//
//  PresentationModeService.swift
//  tabmenu
//

import Foundation
import Observation
import os

/// One switch for "I am sharing my screen": the Mac stays awake, the clipboard stops
/// recording (a shared screen must never leak history), and the notch keeps quiet.
///
/// Everything is restored to how it was — including whether keep-awake was already running
/// for its own reasons.
@Observable
@MainActor
final class PresentationModeService {
    private(set) var isActive = false

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Presentation")
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let keepAwake: KeepAwakeService
    @ObservationIgnored private let notchPanel: NotchWindowController

    @ObservationIgnored private var clipboardWasEnabled = true
    @ObservationIgnored private var startedKeepAwake = false

    /// Marker persisted while presenting, holding the clipboard state to restore. Without it
    /// a quit or crash mid-presentation would leave clipboard history disabled forever.
    private static let suspendedClipboardKey = "presentation.clipboardWasEnabled"

    init(preferences: Preferences, keepAwake: KeepAwakeService, notchPanel: NotchWindowController) {
        self.preferences = preferences
        self.keepAwake = keepAwake
        self.notchPanel = notchPanel
        restoreClipboardIfSuspended()
    }

    /// A previous run ended while presenting; put the clipboard back the way the user had it.
    private func restoreClipboardIfSuspended() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.suspendedClipboardKey) != nil else { return }
        preferences.isClipboardEnabled = defaults.bool(forKey: Self.suspendedClipboardKey)
        defaults.removeObject(forKey: Self.suspendedClipboardKey)
        logger.notice("restored clipboard state after an interrupted presentation")
    }

    func toggle() {
        isActive ? end() : begin()
    }

    private func begin() {
        clipboardWasEnabled = preferences.isClipboardEnabled
        UserDefaults.standard.set(clipboardWasEnabled, forKey: Self.suspendedClipboardKey)
        preferences.isClipboardEnabled = false

        if !keepAwake.isActive {
            // A leftover finite duration must not let the display sleep mid-presentation.
            keepAwake.engage(for: .indefinitely)
            startedKeepAwake = true
        }

        notchPanel.setActivitiesSuppressed(true)
        isActive = true
        logger.notice("presentation mode on")
    }

    private func end() {
        preferences.isClipboardEnabled = clipboardWasEnabled
        UserDefaults.standard.removeObject(forKey: Self.suspendedClipboardKey)
        if startedKeepAwake, keepAwake.isActive {
            keepAwake.toggle()
        }
        startedKeepAwake = false

        notchPanel.setActivitiesSuppressed(false)
        isActive = false
        logger.notice("presentation mode off")
    }
}
