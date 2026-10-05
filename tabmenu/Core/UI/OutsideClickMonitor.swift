//
//  OutsideClickMonitor.swift
//  MagicPlus
//

import AppKit

/// Closes a panel when something outside it is clicked.
///
/// `windowDidResignKey` looks like it covers this and does not. The panels that need it open out of
/// the app's own bar, and the bar is a non-activating panel: clicking it never takes key status away
/// from anything, so a click on the dock left the menu sitting open on top of it. Two monitors are
/// needed and neither is optional — the global one sees clicks in other applications, the local one
/// sees clicks in this one.
///
/// The rectangle the panel opened out of is excluded, because that button already toggles the panel
/// itself. Without that exclusion a click on it would be handled twice: closed here on the way down,
/// reopened by the button on the way up, and the button would never appear to close anything.
@MainActor
final class OutsideClickMonitor {
    private var monitors: [Any] = []

    /// - Parameters:
    ///   - panel: The panel to keep. Clicks inside it are ignored.
    ///   - anchor: The rectangle the panel opened out of, in Cocoa screen coordinates. Clicks there
    ///     belong to whatever drew it.
    ///   - onOutsideClick: What to do about a click anywhere else.
    func start(panel: NSWindow, anchor: CGRect, onOutsideClick: @escaping @MainActor () -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // The window's number rather than the window: these handlers are `@Sendable`, and a number
        // crosses that boundary where an `NSWindow` or an `NSEvent` cannot.
        let panelNumber = panel.windowNumber

        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated {
                guard !anchor.contains(NSEvent.mouseLocation) else { return }
                onOutsideClick()
            }
        })
        if let global { monitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            let insidePanel = event.windowNumber == panelNumber
            MainActor.assumeIsolated {
                guard !insidePanel, !anchor.contains(NSEvent.mouseLocation) else { return }
                onOutsideClick()
            }
            // Passed on either way: closing a panel is not a reason to swallow somebody's click.
            return event
        })
        if let local { monitors.append(local) }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}
