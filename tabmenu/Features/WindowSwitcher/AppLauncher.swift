//
//  AppLauncher.swift
//  tabmenu
//

import AppKit

struct LaunchableApp: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    static func == (lhs: LaunchableApp, rhs: LaunchableApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Finds installed applications so the switcher can open something that is not running yet.
@MainActor
enum AppLauncher {
    private static let searchPaths = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]

    private static var cache: [LaunchableApp] = []
    private static var cachedAt = Date.distantPast
    /// Scanning is cheap but not free, and the set of installed apps barely moves.
    private static let cacheLifetime: TimeInterval = 120

    static func installedApps() -> [LaunchableApp] {
        if Date().timeIntervalSince(cachedAt) < cacheLifetime, !cache.isEmpty { return cache }

        let fileManager = FileManager.default
        var found: [String: LaunchableApp] = [:]

        for path in searchPaths {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: path).appendingPathComponent(entry)
                guard let bundle = Bundle(url: url),
                      let identifier = bundle.bundleIdentifier,
                      found[identifier] == nil
                else { continue }

                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent

                found[identifier] = LaunchableApp(id: identifier, name: name, url: url)
            }
        }

        cache = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedAt = Date()
        return cache
    }

    /// Applications matching a query, excluding ones that already have a window on screen —
    /// those are better reached through the window list above.
    static func matches(for query: String, excluding runningBundleIdentifiers: Set<String>, limit: Int = 5) -> [LaunchableApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        return installedApps()
            .filter { !runningBundleIdentifiers.contains($0.id) }
            .filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted { first, second in
                // Prefix matches read as more relevant than matches buried mid-name.
                let firstStarts = first.name.lowercased().hasPrefix(trimmed.lowercased())
                let secondStarts = second.name.lowercased().hasPrefix(trimmed.lowercased())
                if firstStarts != secondStarts { return firstStarts }
                return first.name.count < second.name.count
            }
            .prefix(limit)
            .map { $0 }
    }

    private static var icons: [String: NSImage] = [:]

    /// The application's icon, kept once it has been read.
    ///
    /// `LaunchableApp.icon` is a computed property that goes to disk through `NSWorkspace` every
    /// time it is read, which is fine for the five rows the switcher shows and not fine for a grid
    /// of every application installed — that asks for a hundred and fifty icons on every pass the
    /// view makes.
    static func icon(for app: LaunchableApp, size: CGFloat) -> NSImage {
        let key = "\(app.id)|\(Int(size))"
        if let cached = icons[key] { return cached }

        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        image.size = NSSize(width: size, height: size)
        // Bounded: a Mac has a few hundred applications, and a cache without a ceiling is a leak
        // with a friendly name.
        if icons.count > 400 { icons.removeAll() }
        icons[key] = image
        return image
    }

    static func launch(_ app: LaunchableApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
