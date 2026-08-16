//
//  AppLanguage.swift
//  MagicPlus
//

import AppKit

/// In-app language override.
///
/// Localization is resolved at process launch from the `AppleLanguages` default, so a change
/// here takes effect after a relaunch — the same key System Settings writes for its per-app
/// language option, which keeps the two pickers consistent with each other.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case turkish

    var id: String { rawValue }

    /// Language names are shown in their own language, as language pickers conventionally do.
    var title: String {
        switch self {
        case .system: String(localized: "System default", comment: "Language picker: follow macOS")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    var code: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .turkish: "tr"
        }
    }

    /// Pure mapping from the stored `AppleLanguages` array, for testing.
    nonisolated static func current(fromStored languages: [String]?) -> AppLanguage {
        guard let first = languages?.first else { return .system }
        if first.hasPrefix("tr") { return .turkish }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    @MainActor
    static var current: AppLanguage {
        // Read only the app's own domain: `UserDefaults.standard` inherits `AppleLanguages`
        // from NSGlobalDomain, which would make "no override" indistinguishable from an
        // explicit choice and leave `.system` unreachable.
        let stored = UserDefaults.standard
            .persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        return current(fromStored: stored)
    }

    @MainActor
    static func apply(_ language: AppLanguage) {
        if let code = language.code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Starts a fresh instance and quits this one, so the new language loads.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
