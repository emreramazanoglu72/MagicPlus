//
//  CameraMirrorView.swift
//  tabmenu
//

import AVFoundation
import SwiftUI
import os

/// Live camera preview, mirrored like a physical mirror. The session only runs while the
/// view is on screen.
struct CameraMirrorView: NSViewRepresentable {
    let isActive: Bool

    func makeNSView(context: Context) -> MirrorNSView {
        MirrorNSView()
    }

    func updateNSView(_ nsView: MirrorNSView, context: Context) {
        isActive ? nsView.start() : nsView.stop()
    }

    static func dismantleNSView(_ nsView: MirrorNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class MirrorNSView: NSView {
    private let logger = Logger(subsystem: "com.tabmenu", category: "Camera")
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    /// Startup runs detached, so a stop that lands mid-flight is recorded here and honored
    /// once `startRunning()` returns — otherwise the camera stays on with no owner.
    private var wantsRunning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    func start() {
        wantsRunning = true
        guard !session.isRunning else { return }

        // macOS will not put a permission prompt in front of a background app, and the notch
        // panel never takes focus, so the app is brought forward before asking.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
        }
        logger.notice("requesting camera access, status=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")

        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor [weak self] in
                self?.logger.notice("camera access granted=\(granted)")
                guard granted else { return }
                self?.configureAndRun()
            }
        }
    }

    func stop() {
        wantsRunning = false
        guard session.isRunning else { return }
        Task.detached(priority: .utility) { [session] in
            session.stopRunning()
        }
    }

    @MainActor
    private func configureAndRun() {
        // The view may have left the screen while the permission prompt was up.
        guard wantsRunning else { return }

        if !isConfigured {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return }

            session.beginConfiguration()
            session.sessionPreset = .high
            session.addInput(input)
            session.commitConfiguration()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            // Mirrored so it behaves like looking into a mirror rather than a camera.
            layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            self.layer?.addSublayer(layer)
            previewLayer = layer
            isConfigured = true
        }

        Task { [weak self, session] in
            // Starting a capture session blocks, so only that part is detached; the decision
            // that follows belongs where this object lives.
            await Task.detached(priority: .userInitiated) { session.startRunning() }.value

            // A stop that landed while startup was in flight must still win.
            guard self?.wantsRunning != true else { return }
            await Task.detached(priority: .userInitiated) { session.stopRunning() }.value
        }
    }
}
