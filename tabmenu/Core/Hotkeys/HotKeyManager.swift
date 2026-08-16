//
//  HotKeyManager.swift
//  tabmenu
//

import AppKit
import Carbon.HIToolbox

/// Registers system-wide shortcuts through the Carbon hot key API, which is still the only
/// way to receive key events without requiring an event tap.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private struct Registration {
        /// `nil` while registrations are paused for shortcut recording.
        var reference: EventHotKeyRef?
        let combo: HotKeyCombo
        let action: () -> Void
    }

    private static let signature: OSType = 0x54424D4E // 'TBMN'

    private var registrationsByCarbonID: [UInt32: Registration] = [:]
    private var carbonIDsByAction: [String: UInt32] = [:]
    private var nextCarbonID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var isPausedForRecording = false

    private init() {
        installEventHandler()
    }

    // MARK: - Registration

    @discardableResult
    func register(_ combo: HotKeyCombo, for action: HotKeyAction, handler: @escaping () -> Void) -> Bool {
        unregister(action)
        guard combo.isValid else { return false }

        let carbonID = nextCarbonID
        nextCarbonID += 1

        var reference: EventHotKeyRef?
        if !isPausedForRecording {
            reference = carbonRegistration(for: combo, carbonID: carbonID)
            guard reference != nil else { return false }
        }
        registrationsByCarbonID[carbonID] = Registration(reference: reference, combo: combo, action: handler)
        carbonIDsByAction[action.id] = carbonID
        return true
    }

    func unregister(_ action: HotKeyAction) {
        guard let carbonID = carbonIDsByAction.removeValue(forKey: action.id),
              let registration = registrationsByCarbonID.removeValue(forKey: carbonID)
        else { return }
        if let reference = registration.reference {
            UnregisterEventHotKey(reference)
        }
    }

    func unregisterAll() {
        for registration in registrationsByCarbonID.values {
            if let reference = registration.reference {
                UnregisterEventHotKey(reference)
            }
        }
        registrationsByCarbonID.removeAll()
        carbonIDsByAction.removeAll()
    }

    // MARK: - Recording support

    /// Suspends every registration so a recorder's key monitor sees combos this app already
    /// owns; Carbon would otherwise consume them before they reach the monitor.
    func pauseRegistrations() {
        guard !isPausedForRecording else { return }
        isPausedForRecording = true
        for (carbonID, registration) in registrationsByCarbonID {
            guard let reference = registration.reference else { continue }
            UnregisterEventHotKey(reference)
            registrationsByCarbonID[carbonID]?.reference = nil
        }
    }

    func resumeRegistrations() {
        guard isPausedForRecording else { return }
        isPausedForRecording = false
        for (carbonID, registration) in registrationsByCarbonID where registration.reference == nil {
            registrationsByCarbonID[carbonID]?.reference = carbonRegistration(for: registration.combo, carbonID: carbonID)
        }
    }

    /// Identifier of the action that currently owns this combo within this app, if any.
    func actionID(owning combo: HotKeyCombo) -> String? {
        carbonIDsByAction.first { registrationsByCarbonID[$0.value]?.combo == combo }?.key
    }

    /// Reports whether another application already owns this shortcut.
    func isAvailable(_ combo: HotKeyCombo) -> Bool {
        var reference: EventHotKeyRef?
        let probeID = UInt32.max - 1
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            combo.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: probeID),
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        UnregisterEventHotKey(reference)
        return true
    }

    private func carbonRegistration(for combo: HotKeyCombo, carbonID: UInt32) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            combo.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: carbonID),
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr else { return nil }
        return reference
    }

    // MARK: - Event handling

    fileprivate func handle(carbonID: UInt32) {
        registrationsByCarbonID[carbonID]?.action()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}

/// Carbon calls back on the main run loop, so hopping onto the main actor is safe here.
private nonisolated let hotKeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handle(carbonID: hotKeyID.id)
    }
    return noErr
}
