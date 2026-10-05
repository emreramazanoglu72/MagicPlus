//
//  MenuBarItemActivator.swift
//  tabmenu
//

import CoreGraphics

/// Clicks a menu bar item on the user's behalf.
///
/// Status items belong to other processes, so there is nothing to send a message to: the
/// only way in is the same synthesized click the hardware would have produced. Coordinates
/// are the window server's, with a top-left origin, which is exactly what the item lister
/// already reports.
enum MenuBarItemActivator {
    static func click(at point: CGPoint, secondary: Bool = false) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let button: CGMouseButton = secondary ? .right : .left
        let down: CGEventType = secondary ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = secondary ? .rightMouseUp : .leftMouseUp

        guard let downEvent = CGEvent(
            mouseEventSource: source,
            mouseType: down,
            mouseCursorPosition: point,
            mouseButton: button
        ),
        let upEvent = CGEvent(
            mouseEventSource: source,
            mouseType: up,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }

        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
    }
}
