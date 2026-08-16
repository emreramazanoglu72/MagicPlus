//
//  ShortcutRecorderField.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// Click-to-record shortcut field. While recording it installs a local key monitor so the
/// captured combination never reaches the rest of the app.
struct ShortcutRecorderField: View {
    let action: HotKeyAction
    @Binding var combo: HotKeyCombo?
    var onChange: (HotKeyCombo?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var conflictMessage: String?
    @State private var recordingToken: UUID?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(label)
                    .font(.callout.monospaced())
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
                    .frame(minWidth: 96)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .help(isRecording ? "Press the new shortcut, or Esc to cancel" : "Click to record a shortcut")

            Button {
                clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(combo == nil ? 0 : 1)
            .disabled(combo == nil)
            .help("Remove shortcut")
            .accessibilityLabel("Remove shortcut for \(action.title)")
        }
        .overlay(alignment: .bottomLeading) {
            if let conflictMessage {
                Text(conflictMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .offset(y: 14)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Recording…" }
        return combo?.displayString ?? "Not set"
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard monitor == nil else { return }
        recordingToken = ShortcutRecorderCoordinator.shared.begin { stopRecording() }
        // The app's own registrations would consume an already-bound combo before it reaches
        // the monitor, so they stay suspended until recording ends.
        HotKeyManager.shared.pauseRegistrations()
        isRecording = true
        conflictMessage = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        isRecording = false
        if let recordingToken {
            ShortcutRecorderCoordinator.shared.end(recordingToken)
            self.recordingToken = nil
        }
        HotKeyManager.shared.resumeRegistrations()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { // Escape
            stopRecording()
            return
        }

        let candidate = HotKeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags)
        guard candidate.isValid else {
            conflictMessage = "Add ⌘, ⌥ or ⌃"
            return
        }
        if let owner = conflictingAction(for: candidate) {
            conflictMessage = String(
                localized: "Already used by \(owner.title)",
                comment: "Recorder rejects a combo bound to another action in this app; placeholder is that action's name"
            )
            return
        }
        guard HotKeyManager.shared.isAvailable(candidate) else {
            conflictMessage = "Already used by another app"
            return
        }

        combo = candidate
        onChange(candidate)
        conflictMessage = nil
        stopRecording()
    }

    /// This app's action that already owns the combo, unless it is the row being edited —
    /// re-assigning a shortcut to its own action stays allowed.
    private func conflictingAction(for candidate: HotKeyCombo) -> HotKeyAction? {
        guard let ownerID = HotKeyManager.shared.actionID(owning: candidate), ownerID != action.id
        else { return nil }
        return HotKeyAction.allCases.first { $0.id == ownerID }
    }

    private func clear() {
        combo = nil
        onChange(nil)
        conflictMessage = nil
    }
}

/// Ensures at most one recorder field captures keys at a time: starting a new recording
/// cleanly ends the previously active one, so a keypress can never land in two rows.
@MainActor
private final class ShortcutRecorderCoordinator {
    static let shared = ShortcutRecorderCoordinator()

    private var activeToken = UUID()
    private var stopActiveRecorder: (() -> Void)?

    /// Stops any recorder that is already active and returns a token for the new session.
    func begin(stop: @escaping () -> Void) -> UUID {
        stopActiveRecorder?()
        let token = UUID()
        activeToken = token
        stopActiveRecorder = stop
        return token
    }

    func end(_ token: UUID) {
        guard token == activeToken else { return }
        stopActiveRecorder = nil
    }
}
