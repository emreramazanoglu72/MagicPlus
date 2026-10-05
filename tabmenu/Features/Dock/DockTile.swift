//
//  DockTile.swift
//  MagicPlus
//

import AppKit

/// One thing in the dock.
nonisolated struct DockTile: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case application(bundleIdentifier: String?)
        case folder
        case file
        case separator
        case trash
    }

    let id: String
    let kind: Kind
    let url: URL?
    let name: String
    /// True for a running app that is not pinned, which the dock shows after the pinned ones the
    /// way macOS does.
    var isTransient: Bool = false
    var isRunning: Bool = false

    var bundleIdentifier: String? {
        if case .application(let identifier) = kind { return identifier }
        return nil
    }

    var isApplication: Bool {
        if case .application = kind { return true }
        return false
    }
}

/// Where the dock's contents come from.
///
/// From the real Dock's own preferences, deliberately. Someone who has arranged their Dock over
/// years should not have to arrange it again to try a different look, and a dock that starts empty
/// — or worse, guesses — is a dock nobody keeps switched on for more than a minute. The pinned
/// icons, their order and the folders on the right are read exactly as `Dock.app` stores them.
///
/// Nothing is written back here. Rearranging the real Dock is the real Dock's business, and a
/// replacement that quietly rewrote it would be the worst of both.
nonisolated enum DockTileSource {
    private static let appsKey = "persistent-apps"
    private static let othersKey = "persistent-others"
    private static let spacerTypes = ["spacer-tile", "small-spacer-tile", "flex-spacer-tile"]

    /// - Parameter domain: The Dock's preferences domain. Overridden by tests.
    static func pinnedTiles(domain: String = "com.apple.dock") -> [DockTile] {
        let apps = list(appsKey, in: domain).enumerated().compactMap { index, entry in
            tile(from: entry, index: index, isFolderList: false)
        }
        let others = list(othersKey, in: domain).enumerated().compactMap { index, entry in
            tile(from: entry, index: index, isFolderList: true)
        }
        return apps + others
    }

    private static func list(_ key: String, in domain: String) -> [[String: Any]] {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [[String: Any]] ?? []
    }

    private static func tile(from entry: [String: Any], index: Int, isFolderList: Bool) -> DockTile? {
        let type = entry["tile-type"] as? String ?? ""
        let data = entry["tile-data"] as? [String: Any] ?? [:]
        let prefix = isFolderList ? "other" : "app"

        if spacerTypes.contains(type) {
            return DockTile(id: "\(prefix).spacer.\(index)", kind: .separator, url: nil, name: "")
        }

        let url = (data["file-data"] as? [String: Any])?["_CFURLString"] as? String
        let resolved = url.flatMap { URL(string: $0) }
        // The label the Dock itself shows, which is localised — "Uygulamalar" rather than
        // "Applications" — and therefore the right one to repeat.
        let name = data["file-label"] as? String
            ?? resolved?.deletingPathExtension().lastPathComponent
            ?? ""

        guard let resolved else { return nil }

        let kind: DockTile.Kind = switch type {
        case "directory-tile": .folder
        case "file-tile" where resolved.pathExtension == "app": .application(
            bundleIdentifier: data["bundle-identifier"] as? String
        )
        default: isFolderList ? .file : .application(bundleIdentifier: data["bundle-identifier"] as? String)
        }

        return DockTile(
            id: "\(prefix).\(resolved.path).\(index)",
            kind: kind,
            url: resolved,
            name: name
        )
    }

    /// Tiles for a list of bundle identifiers this app keeps itself.
    ///
    /// Resolved through `NSWorkspace` rather than stored paths: an application that moved, or was
    /// reinstalled somewhere else, still resolves — a stored path would leave a tile that opens
    /// nothing.
    @MainActor
    static func pinnedTiles(identifiers: [String]) -> [DockTile] {
        identifiers.enumerated().compactMap { index, identifier in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            else { return nil }
            return DockTile(
                id: "pin.\(identifier)",
                kind: .application(bundleIdentifier: identifier),
                url: url,
                name: FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: ""),
                isTransient: false
            )
        }
    }

    /// The identifiers the system Dock is keeping, to start our own list from.
    @MainActor
    static func systemDockIdentifiers() -> [String] {
        pinnedTiles().compactMap(\.bundleIdentifier)
    }

    /// Regular apps that are running but not pinned, in a stable order so the dock does not
    /// reshuffle itself every time something is launched.
    @MainActor
    static func runningTiles(excluding pinned: [DockTile]) -> [DockTile] {
        let pinnedIdentifiers = Set(pinned.compactMap(\.bundleIdentifier))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { application in
                guard let identifier = application.bundleIdentifier else { return false }
                // The app drawing the dock does not belong in it.
                return !pinnedIdentifiers.contains(identifier)
                    && identifier != Bundle.main.bundleIdentifier
            }
            .compactMap { application in
                guard let identifier = application.bundleIdentifier else { return nil }
                return DockTile(
                    id: "running.\(identifier)",
                    kind: .application(bundleIdentifier: identifier),
                    url: application.bundleURL,
                    name: application.localizedName ?? identifier,
                    isTransient: true,
                    isRunning: true
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Which of these apps are running now.
    @MainActor
    static func runningIdentifiers() -> Set<String> {
        Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
        )
    }
}
