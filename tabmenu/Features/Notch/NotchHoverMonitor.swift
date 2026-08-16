//
//  NotchHoverMonitor.swift
//  tabmenu
//

import AppKit

/// Reports pointer movement near the notch, including during drags so files can be dropped
/// onto the shelf without opening the panel first.
@MainActor
final class NotchHoverMonitor {
    var onMove: ((_ location: CGPoint, _ isDragging: Bool) -> Void)?
    /// Left clicks anywhere on screen — the island window ignores mouse events while
    /// collapsed, so capsule clicks arrive here instead of through AppKit.
    var onClick: ((_ location: CGPoint) -> Void)?

    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.report(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.report(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func report(_ event: NSEvent) {
        onMove?(NSEvent.mouseLocation, event.type == .leftMouseDragged)
        if event.type == .leftMouseUp {
            onClick?(NSEvent.mouseLocation)
        }
    }
}
