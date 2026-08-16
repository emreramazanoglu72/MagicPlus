//
//  WindowThumbnailService.swift
//  tabmenu
//

import AppKit
import Observation
import ScreenCaptureKit
import os

/// Captures and caches window thumbnails through ScreenCaptureKit.
///
/// Captures are batched: enumerating shareable content is the expensive part, so one
/// enumeration serves every window in a request.
@Observable
@MainActor
final class WindowThumbnailService {
    private(set) var thumbnails: [CGWindowID: NSImage] = [:]

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Thumbnails")
    @ObservationIgnored private let permission: ScreenRecordingPermission
    @ObservationIgnored private var captureTask: Task<Void, Never>?

    /// Long edge of a stored thumbnail, in points.
    private static let maximumEdge: CGFloat = 320

    init(permission: ScreenRecordingPermission? = nil) {
        self.permission = permission ?? .shared
    }

    var isAvailable: Bool { permission.isGranted }

    func thumbnail(for windowID: CGWindowID?) -> NSImage? {
        guard let windowID else { return nil }
        return thumbnails[windowID]
    }

    /// Refreshes thumbnails for the given windows, replacing any in-flight request.
    func refresh(windowIDs: [CGWindowID]) {
        guard permission.isGranted, !windowIDs.isEmpty else { return }
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            await self?.capture(windowIDs: windowIDs)
        }
    }

    func clear() {
        captureTask?.cancel()
        captureTask = nil
        thumbnails.removeAll()
    }

    private func capture(windowIDs: [CGWindowID]) async {
        let requested = Set(windowIDs)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let targets = content.windows.filter { requested.contains($0.windowID) }

            for window in targets {
                guard !Task.isCancelled else { return }
                guard let image = await capture(window) else { continue }
                thumbnails[window.windowID] = image
            }
        } catch {
            logger.error("Shareable content unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func capture(_ window: SCWindow) async -> NSImage? {
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return nil }

        let scale = min(Self.maximumEdge / max(frame.width, frame.height), 1)
        let configuration = SCStreamConfiguration()
        // Rendered at 2x so the thumbnail stays sharp on Retina displays.
        configuration.width = max(1, Int(frame.width * scale * 2))
        configuration.height = max(1, Int(frame.height * scale * 2))
        configuration.showsCursor = false
        configuration.ignoreGlobalClipDisplay = true
        configuration.scalesToFit = true

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
            )
        } catch {
            logger.debug("Capture failed for window \(window.windowID): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
