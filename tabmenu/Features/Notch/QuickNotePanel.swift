//
//  QuickNotePanel.swift
//  tabmenu
//

import AppKit
import Carbon.HIToolbox
import SwiftUI
import os

/// Captures a thought into a text file on the shelf without opening an editor.
@MainActor
final class QuickNotePanelController: NSObject, NSWindowDelegate {
    @Observable
    final class Model {
        var text = ""
    }

    private let model = Model()
    private let shelf: ShelfStore
    private let frontmostTracker: FrontmostApplicationTracker
    private let logger = Logger(subsystem: "com.tabmenu", category: "QuickNote")

    /// Called after a note lands on the shelf, so the notch can say so.
    var onSaved: (() -> Void)?

    private var panel: NSPanel?
    private var keyMonitor: Any?

    private static let panelSize = CGSize(width: 420, height: 240)

    init(shelf: ShelfStore, frontmostTracker: FrontmostApplicationTracker) {
        self.shelf = shelf
        self.frontmostTracker = frontmostTracker
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        frontmostTracker.remember()
        model.text = ""

        let panel = panel ?? makePanel()
        self.panel = panel
        FloatingPanel.center(panel, size: Self.panelSize)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyMonitor()
    }

    func hide() {
        stopKeyMonitor()
        panel?.orderOut(nil)
        frontmostTracker.restore()
    }

    private func save() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hide()
            return
        }

        let directory = AppSupportDirectory.url().appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = directory.appendingPathComponent("Note \(formatter.string(from: Date())).txt")

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shelf.add([url])
            onSaved?()
        } catch {
            logger.error("failed to save note: \(error.localizedDescription, privacy: .public)")
        }
        hide()
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel.make(
            size: Self.panelSize,
            title: String(localized: "Quick Note", comment: "Floating panel title"),
            content: QuickNoteView(model: model)
        )
        panel.delegate = self
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }

            switch Int(event.keyCode) {
            case kVK_Escape:
                self.hide()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                guard event.modifierFlags.contains(.command) else { return event }
                self.save()
                return nil
            default:
                return event
            }
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct QuickNoteView: View {
    @Bindable var model: QuickNotePanelController.Model
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(Accent.windows.gradient)
                Text("Quick Note")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider().opacity(0.5)

            TextEditor(text: $model.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .focused($isFocused)

            Divider().opacity(0.5)

            HStack(spacing: 12) {
                KeyHint(keys: "⌘↩", label: "Save to shelf")
                Spacer()
                KeyHint(keys: "esc", label: "Discard")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.ultraThickMaterial)
        .onAppear { isFocused = true }
    }
}
