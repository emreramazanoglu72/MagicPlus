//
//  WorkspaceLayoutStore.swift
//  tabmenu
//

import AppKit
import Observation
import os

/// One window's position within a saved arrangement.
struct WindowPlacement: Codable, Hashable {
    let bundleIdentifier: String
    let applicationName: String
    let title: String
    /// Bounds in Accessibility space.
    let frame: CGRect
}

struct WorkspaceLayout: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    let createdAt: Date
    var placements: [WindowPlacement]

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), placements: [WindowPlacement]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.placements = placements
    }

    var applicationNames: [String] {
        var seen = Set<String>()
        return placements.compactMap { seen.insert($0.applicationName).inserted ? $0.applicationName : nil }
    }
}

/// Captures and restores whole window arrangements.
@Observable
@MainActor
final class WorkspaceLayoutStore {
    private(set) var layouts: [WorkspaceLayout] = []
    /// Result of the last restore, surfaced in the UI.
    private(set) var lastRestoreSummary: String?

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Layouts")
    @ObservationIgnored private let storageURL: URL

    /// Slots reachable by keyboard shortcut.
    static let shortcutSlotCount = 3
    private static let limit = 12

    init() {
        storageURL = AppSupportDirectory.url().appendingPathComponent("layouts.json")
        load()
    }

    // MARK: - Capture

    /// Snapshots every standard window that is currently open.
    @discardableResult
    func capture(name: String) -> WorkspaceLayout? {
        let placements = WindowLister.switchableWindows().compactMap { window -> WindowPlacement? in
            guard let bundleIdentifier = window.bundleIdentifier,
                  let frame = window.frame,
                  !window.isMinimized
            else { return nil }

            return WindowPlacement(
                bundleIdentifier: bundleIdentifier,
                applicationName: window.applicationName,
                title: window.title,
                frame: frame
            )
        }

        guard !placements.isEmpty else {
            lastRestoreSummary = String(
                localized: "Nothing to save — no windows found.",
                comment: "Shown when saving a layout with no open windows"
            )
            return nil
        }

        let layout = WorkspaceLayout(name: name, placements: placements)
        layouts.insert(layout, at: 0)
        if layouts.count > Self.limit { layouts.removeLast(layouts.count - Self.limit) }
        save()
        return layout
    }

    // MARK: - Restore

    /// Matches saved placements against open windows and moves them back.
    ///
    /// Matching prefers an exact title within the same app, then falls back to any unused
    /// window of that app, so a renamed document still lands in the right place.
    @discardableResult
    func apply(_ layout: WorkspaceLayout) -> Int {
        var available = WindowLister.switchableWindows()
        var restored = 0

        for placement in layout.placements {
            guard let index = matchIndex(for: placement, in: available) else { continue }
            let window = available.remove(at: index)
            if WindowLister.setFrame(placement.frame, for: window) { restored += 1 }
        }

        let missing = layout.placements.count - restored
        lastRestoreSummary = missing == 0
            ? String(localized: "Restored \(restored) windows.",
                     comment: "Layout restored fully; placeholder is the number of windows")
            : String(localized: "Restored \(restored) of \(layout.placements.count); \(missing) not open.",
                     comment: "Layout partly restored: restored count, total count, missing count")
        logger.notice("applied layout \(layout.name, privacy: .public): \(restored)/\(layout.placements.count)")
        return restored
    }

    func apply(slot: Int) {
        guard layouts.indices.contains(slot) else { return }
        apply(layouts[slot])
    }

    private func matchIndex(for placement: WindowPlacement, in windows: [SwitchableWindow]) -> Int? {
        Self.matchIndex(
            for: placement,
            in: windows.map { (bundleIdentifier: $0.bundleIdentifier, title: $0.title) }
        )
    }

    /// Pure matching rule, split out so it can be exercised without live windows.
    ///
    /// Prefers an exact title within the same app, then falls back to any window of that app,
    /// so a renamed document still lands in the right place.
    static func matchIndex(
        for placement: WindowPlacement,
        in windows: [(bundleIdentifier: String?, title: String)]
    ) -> Int? {
        if let exact = windows.firstIndex(where: {
            $0.bundleIdentifier == placement.bundleIdentifier && $0.title == placement.title
        }) {
            return exact
        }
        return windows.firstIndex { $0.bundleIdentifier == placement.bundleIdentifier }
    }

    // MARK: - Editing

    func rename(_ layout: WorkspaceLayout, to name: String) {
        guard let index = layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        layouts[index].name = trimmed
        save()
    }

    func delete(_ layout: WorkspaceLayout) {
        layouts.removeAll { $0.id == layout.id }
        save()
    }

    func clearSummary() {
        lastRestoreSummary = nil
    }

    /// Shortcut label for a layout, when it occupies one of the bound slots.
    func slot(of layout: WorkspaceLayout) -> Int? {
        guard let index = layouts.firstIndex(where: { $0.id == layout.id }),
              index < Self.shortcutSlotCount
        else { return nil }
        return index
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            layouts = try JSONDecoder().decode([WorkspaceLayout].self, from: data)
        } catch {
            // Set the unreadable file aside so the next save cannot clobber user data.
            logger.error("Failed to load layouts: \(error.localizedDescription, privacy: .public)")
            let quarantineURL = storageURL.appendingPathExtension("corrupted")
            try? FileManager.default.removeItem(at: quarantineURL)
            try? FileManager.default.moveItem(at: storageURL, to: quarantineURL)
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(layouts).write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Failed to save layouts: \(error.localizedDescription, privacy: .public)")
        }
    }
}
