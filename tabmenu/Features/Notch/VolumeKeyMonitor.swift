//
//  VolumeKeyMonitor.swift
//  tabmenu
//

import AppKit

/// Watches the hardware volume keys so the island can show the level as it changes.
///
/// The system's own HUD cannot be suppressed, so this is deliberately a second, richer
/// readout in the notch rather than a replacement for it.
@MainActor
final class VolumeKeyMonitor {
    var onVolumeKey: (() -> Void)?

    private var monitors: [Any] = []

    // From IOKit's `ev_keymap.h`, which is not bridged into Swift.
    private static let soundUpKey: Int32 = 0
    private static let soundDownKey: Int32 = 1
    private static let muteKey: Int32 = 7
    /// `NSSystemDefined` subtype carrying the media and volume keys.
    private static let auxControlSubtype: Int16 = 8

    func start() {
        guard monitors.isEmpty else { return }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.systemDefined], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        guard event.subtype.rawValue == Self.auxControlSubtype else { return }

        let keyCode = Int32((event.data1 & 0xFFFF_0000) >> 16)
        let isKeyDown = ((event.data1 & 0x0000_FF00) >> 8) == 0x0A
        guard isKeyDown else { return }

        switch keyCode {
        case Self.soundUpKey, Self.soundDownKey, Self.muteKey:
            onVolumeKey?()
        default:
            break
        }
    }
}
