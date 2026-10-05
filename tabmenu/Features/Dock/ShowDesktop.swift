//
//  ShowDesktop.swift
//  MagicPlus
//

import AppKit

/// Clears the screen, and puts it back.
///
/// The Windows behaviour, which is what was asked for: one click and the desktop is there, another
/// and everything is as it was. macOS has its own Show Desktop on F11, and posting that key was the
/// first idea — it is the native animation, and it depends on a keyboard shortcut the user is free
/// to change or switch off, with no way to find out that it did nothing. Hiding the applications is
/// public API, needs no permission at all, and can be checked.
///
/// The applications hidden are remembered rather than re-derived, because "everything that is
/// hidden" is not the same set as "everything this hid": an application somebody hid themselves
/// before pressing this should still be hidden after pressing it again.
@MainActor
enum ShowDesktop {
    /// What this hid, in the order it hid them.
    private static var hiddenByUs: [pid_t] = []

    static var isShowingDesktop: Bool { !hiddenByUs.isEmpty }

    static func toggle() {
        isShowingDesktop ? restore() : clearTheScreen()
    }

    private static func clearTheScreen() {
        let ourself = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications

        let candidates = running.map {
            Candidate(
                processIdentifier: $0.processIdentifier,
                isRegular: $0.activationPolicy == .regular,
                isAlreadyHidden: $0.isHidden,
                isOurself: $0.processIdentifier == ourself
            )
        }

        var hidden: [pid_t] = []
        for identifier in choose(from: candidates) {
            guard let application = running.first(where: { $0.processIdentifier == identifier })
            else { continue }
            // An application may refuse, and one that does must not be remembered as hidden —
            // unhiding it later would bring forward something that never went away.
            if application.hide() { hidden.append(identifier) }
        }
        hiddenByUs = hidden
    }

    private static func restore() {
        for identifier in hiddenByUs.reversed() {
            NSRunningApplication(processIdentifier: identifier)?.unhide()
        }
        hiddenByUs.removeAll()
    }

    /// Forgets what it was holding, for when the screen has plainly been used since.
    static func forget() {
        hiddenByUs.removeAll()
    }

    // MARK: - Choosing

    /// The bare facts about a running application that decide whether it should go.
    nonisolated struct Candidate: Equatable, Sendable {
        let processIdentifier: pid_t
        /// Regular applications have windows and a Dock tile. Agents and accessories have neither,
        /// so hiding them clears nothing and can stop things people rely on.
        let isRegular: Bool
        let isAlreadyHidden: Bool
        let isOurself: Bool
    }

    /// Which of them to hide.
    ///
    /// Kept as a function of plain values so it can be tested: `NSRunningApplication` cannot be
    /// constructed, and the three exclusions here are exactly the sort that get lost in a rewrite.
    nonisolated static func choose(from candidates: [Candidate]) -> [pid_t] {
        candidates
            .filter { $0.isRegular && !$0.isAlreadyHidden && !$0.isOurself }
            .map(\.processIdentifier)
    }
}
