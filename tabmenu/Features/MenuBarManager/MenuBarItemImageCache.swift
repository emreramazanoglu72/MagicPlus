//
//  MenuBarItemImageCache.swift
//  tabmenu
//

import AppKit
import Observation
import ScreenCaptureKit
import os

/// Keeps a picture of each menu bar item so hidden ones can be shown somewhere else.
///
/// The pictures are captured while the items are on screen and kept afterwards, because an
/// item that has been pushed out of the bar can no longer be captured — which is precisely
/// when its picture is needed. Without Screen Recording nothing is captured at all and the
/// surfaces fall back to the owning app's icon.
@Observable
@MainActor
final class MenuBarItemImageCache {
    private(set) var images: [String: NSImage] = [:]

    @ObservationIgnored private let permission: ScreenRecordingPermission
    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "MenuBarImages")
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var lastCapture: Date?

    /// Captures are throttled: a status item's artwork changes far more slowly than the
    /// surfaces that show it are redrawn.
    private static let minimumInterval: TimeInterval = 2

    init(permission: ScreenRecordingPermission? = nil) {
        self.permission = permission ?? .shared
    }

    var isAvailable: Bool { permission.isGranted }

    func image(for item: MenuBarItem) -> NSImage? { images[item.key] }

    /// Refreshes the pictures of every item that is currently on screen.
    func refresh(for items: [MenuBarItem], force: Bool = false) {
        guard permission.isGranted else { return }
        if !force, let lastCapture, Date().timeIntervalSince(lastCapture) < Self.minimumInterval { return }
        lastCapture = Date()

        let targets = items.filter { $0.isOnScreen && $0.frame.width > 1 }
        guard !targets.isEmpty else { return }

        captureTask?.cancel()
        captureTask = Task { [weak self] in
            await self?.capture(targets)
        }
    }

    private func capture(_ items: [MenuBarItem]) async {
        let byWindowID = Dictionary(items.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            for window in content.windows {
                guard !Task.isCancelled else { return }
                guard let item = byWindowID[window.windowID] else { continue }
                guard let image = await capture(window) else { continue }
                images[item.key] = image
            }
        } catch {
            logger.debug("Menu bar capture unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func capture(_ window: SCWindow) async -> NSImage? {
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(frame.width * 2)
        configuration.height = Int(frame.height * 2)
        configuration.showsCursor = false
        configuration.ignoreGlobalClipDisplay = true
        configuration.scalesToFit = true

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
            return NSImage(cgImage: cgImage, size: NSSize(width: frame.width, height: frame.height))
        } catch {
            return nil
        }
    }
}
