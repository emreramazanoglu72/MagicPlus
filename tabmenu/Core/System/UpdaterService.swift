//
//  UpdaterService.swift
//  MagicPlus
//

import Sparkle

/// Sparkle-based updates for the direct-download build.
///
/// The feed URL and EdDSA public key live in Config/Info.plist. Until a real key ships
/// (SUPublicEDKey), the updater is never started and the menu item is hidden — without the
/// key, Sparkle's only remaining validation is the Apple code-signing fallback, which would
/// accept any same-team build served by whoever controls the feed host. Once the key is in
/// place, the menu item works and reports its errors visibly, so a misconfigured feed is
/// never a silent failure.
@MainActor
final class UpdaterService {
    /// True once Info.plist carries a non-empty SUPublicEDKey.
    static let isConfigured =
        (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false

    private let controller: SPUStandardUpdaterController?

    init() {
        controller = UpdaterService.isConfigured
            ? SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            : nil
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
