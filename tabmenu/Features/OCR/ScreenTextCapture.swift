//
//  ScreenTextCapture.swift
//  tabmenu
//

import AppKit
import Vision
import os

/// Interactive region capture that lands as *text* on the clipboard rather than an image.
///
/// The system's own `screencapture -i` draws the region selector, so the interaction is the
/// familiar ⌘⇧4 crosshair; the captured image never leaves a temporary file that is deleted
/// straight after recognition.
enum ScreenTextCapture {
    nonisolated static let logger = Logger(subsystem: "com.tabmenu", category: "OCR")

    /// Lets the user select a region, recognises the text in it, and puts it on the
    /// clipboard. Returns the number of characters captured, or `nil` when the user
    /// cancelled or nothing was recognised.
    static func capture() async -> Int? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabmenu-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        guard await runScreencapture(to: fileURL),
              let image = NSImage(contentsOf: fileURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        guard let text = await recognizeText(in: image), !text.isEmpty else {
            logger.notice("capture finished with no recognisable text")
            return nil
        }

        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        logger.notice("captured \(text.count) characters of text")
        return text.count
    }

    // MARK: - Pieces

    /// `-i` interactive selection, `-x` no shutter sound, `-t png`.
    private nonisolated static func runScreencapture(to url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-t", "png", url.path]
            process.terminationHandler = { _ in
                let captured = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } ?? false
                continuation.resume(returning: captured)
            }
            do {
                try process.run()
            } catch {
                logger.error("screencapture failed to start: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: false)
            }
        }
    }

    private nonisolated static func recognizeText(in image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines?.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["tr-TR", "en-US"]

            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                logger.error("text recognition failed: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: nil)
            }
        }
    }
}
