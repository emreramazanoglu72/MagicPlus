//
//  WindowRuleStore.swift
//  tabmenu
//

import AppKit
import Observation
import os

/// "Whenever this app opens, put it here."
struct WindowRule: Identifiable, Codable, Hashable {
    let id: UUID
    var bundleIdentifier: String
    var applicationName: String
    var zone: WindowZone

    init(id: UUID = UUID(), bundleIdentifier: String, applicationName: String, zone: WindowZone) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.zone = zone
    }
}

/// Applies placement rules when an application launches.
///
/// An app is running before its window exists, so each launch is retried a few times and
/// then given up on — that keeps a background helper with no windows from being polled
/// forever.
@Observable
@MainActor
final class WindowRuleStore {
    private(set) var rules: [WindowRule] = []

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "WindowRules")
    @ObservationIgnored private let windowManager: WindowManagerService
    @ObservationIgnored private let permission: AccessibilityPermission
    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private var observer: NSObjectProtocol?

    private static let retryDelays: [Duration] = [.milliseconds(600), .seconds(1), .seconds(2)]

    init(windowManager: WindowManagerService, permission: AccessibilityPermission? = nil) {
        self.windowManager = windowManager
        self.permission = permission ?? .shared

        storageURL = AppSupportDirectory.url().appendingPathComponent("window-rules.json")
        load()
    }

    // MARK: - Lifecycle

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated { self.applyRule(for: application) }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    // MARK: - Editing

    func add(bundleIdentifier: String, applicationName: String, zone: WindowZone) {
        guard !rules.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        rules.append(WindowRule(bundleIdentifier: bundleIdentifier, applicationName: applicationName, zone: zone))
        rules.sort { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
        save()
    }

    func update(_ rule: WindowRule, zone: WindowZone) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].zone = zone
        save()
    }

    func remove(_ rule: WindowRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    // MARK: - Applying

    private func applyRule(for application: NSRunningApplication) {
        guard permission.isTrusted,
              let bundleIdentifier = application.bundleIdentifier,
              let rule = rules.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return }

        Task { await place(application: application, using: rule) }
    }

    private func place(application: NSRunningApplication, using rule: WindowRule) async {
        for delay in Self.retryDelays {
            try? await Task.sleep(for: delay)
            guard !application.isTerminated else { return }

            let windows = WindowLister.windows(ofProcessIdentifier: application.processIdentifier)
            guard let window = windows.first else { continue }

            let accessibilityWindow = AccessibilityWindow(
                element: window.element,
                processIdentifier: window.processIdentifier,
                applicationName: window.applicationName,
                title: window.title
            )
            windowManager.snap(accessibilityWindow, to: rule.zone)
            logger.notice("applied rule \(rule.zone.rawValue, privacy: .public) to \(rule.applicationName, privacy: .public)")
            return
        }

        logger.notice("no window appeared for \(rule.applicationName, privacy: .public)")
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            rules = try JSONDecoder().decode([WindowRule].self, from: data)
        } catch {
            // Set the unreadable file aside so the next save cannot clobber user data.
            logger.error("Failed to load rules: \(error.localizedDescription, privacy: .public)")
            let quarantineURL = storageURL.appendingPathExtension("corrupted")
            try? FileManager.default.removeItem(at: quarantineURL)
            try? FileManager.default.moveItem(at: storageURL, to: quarantineURL)
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(rules).write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Failed to save rules: \(error.localizedDescription, privacy: .public)")
        }
    }
}
