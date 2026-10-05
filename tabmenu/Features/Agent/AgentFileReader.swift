//
//  AgentFileReader.swift
//  MagicPlus
//

import AppKit
import PDFKit
import Vision

/// Reads a file for the assistant.
///
/// The gap this closes: the assistant could find a file and not say a word about what was in it,
/// which is the first thing anybody asks about a file. One tool rather than three — a measured
/// seven-model comparison showed small models failing at *choosing* between tools long before they
/// failed at using one — so text, PDFs and pictures all arrive here and the file decides.
///
/// Reading is the one thing this app does that takes something private and sends it to somebody
/// else's computer. That is why the policy below exists and why it is a separate, testable function
/// rather than a condition buried in the reading.
nonisolated enum AgentFileReader {
    /// Why a file will not be read. Each answers the model in words it can act on, because "no" with
    /// a reason gets a sensible second attempt and a bare "no" gets the same request again.
    enum Refusal: Equatable {
        case missing
        case outsideHome
        case secret
        case tooLarge(Int)
        case unreadableKind(String)

        var message: String {
            switch self {
            case .missing:
                "There is no file at that path."
            case .outsideHome:
                "That is outside the user's home folder, and this only reads files from inside it."
            case .secret:
                "That path holds credentials, and this will not read it. Ask the user to open it."
            case .tooLarge(let megabytes):
                "That file is about \(megabytes) MB — too large to read. Ask for a narrower question."
            case .unreadableKind(let type):
                "That is a \(type) file and its contents cannot be read as text."
            }
        }
    }

    /// How much of a file travels. Twenty thousand characters is about five thousand tokens: enough
    /// to summarise a long document, little enough not to spend a conversation's whole budget on one
    /// call. What is cut is said so, rather than the model believing it read the end.
    static let characterLimit = 20_000

    /// Files this refuses to read, wherever they are.
    ///
    /// Not a security boundary — anything running as the user can read these — but a boundary
    /// against *sending* them somewhere. A model can be steered by a filename, and the difference
    /// between opening a private key and posting it to an API is the whole of the risk here.
    private static let secretComponents = [
        ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".netrc", ".npmrc",
        "keychains", "login.keychain", "credentials"
    ]
    private static let secretNames = ["id_rsa", "id_ed25519", ".env", ".env.local", ".htpasswd"]

    /// The path as a file system URL, with `~` meaning what everybody means by it.
    ///
    /// Models write `~/Documents/notes.txt` because people do, and `URL(fileURLWithPath:)` reads the
    /// tilde as an ordinary folder name — so the path landed outside the home folder and the read
    /// was refused for being somewhere it was not. Found by asking the assistant a real question
    /// about a real file.
    static func resolve(_ path: String, home: String) -> URL {
        var expanded = path
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + String(expanded.dropFirst(1))
        } else if !expanded.hasPrefix("/") {
            // A bare name or a relative path means the home folder, not wherever this process
            // happens to have been started. Measured: a model asked to read `notes.txt` had it
            // resolved against the working directory and was told the file was "outside the user's
            // home folder" — a true sentence about a path nobody meant.
            expanded = home + "/" + expanded
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// Whether this file may be read, or why not.
    static func refusal(for path: String, home: String) -> Refusal? {
        let url = resolve(path, home: home)
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL

        // Standardized first, so `~/Documents/../../etc/passwd` is judged as `/etc/passwd`.
        guard url.path == homeURL.path || url.path.hasPrefix(homeURL.path + "/") else {
            return .outsideHome
        }

        let lowercased = url.pathComponents.map { $0.lowercased() }
        if lowercased.contains(where: secretComponents.contains) { return .secret }
        if secretNames.contains(url.lastPathComponent.lowercased()) { return .secret }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        if isDirectory.boolValue { return .unreadableKind("folder") }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Read before the size is known would mean loading it to find out it was too big.
        if size > 50 * 1024 * 1024 { return .tooLarge(size / 1024 / 1024) }

        return nil
    }

    /// The file's text, or a sentence saying why there is none.
    static func read(path: String, home: String) async -> String {
        if let refusal = refusal(for: path, home: home) { return refusal.message }

        let url = resolve(path, home: home)
        let text = await Task.detached(priority: .userInitiated) { () -> String? in
            switch url.pathExtension.lowercased() {
            case "pdf": return pdfText(at: url)
            case "png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp", "webp": return nil
            default: return plainText(at: url)
            }
        }.value

        if let text { return trimmed(text, of: url) }

        // Pictures go the long way round, because Vision is the only thing that can read them.
        if let recognised = await imageText(at: url) { return trimmed(recognised, of: url) }

        return Refusal.unreadableKind(url.pathExtension.isEmpty ? "binary" : url.pathExtension).message
    }

    // MARK: - By kind

    private static func plainText(at url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        // Older files and other locales: let the system work the encoding out.
        var encoding = String.Encoding.utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }

    private static func pdfText(at url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        guard let text = document.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Text recognised in a picture. A scanned page is a picture, and so is a screenshot of an
    /// error somebody wants explained — which is most of why this is here.
    private static func imageText(at url: URL) async -> String? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Cut to the limit, and honest about it. A model that believes it read the end of a document
    /// will answer questions about the end of a document.
    static func trimmed(_ text: String, of url: URL) -> String {
        guard text.count > characterLimit else { return text }
        let kept = String(text.prefix(characterLimit))
        return kept + "\n\n[Cut here: \(url.lastPathComponent) is \(text.count) characters and only "
            + "the first \(characterLimit) were read.]"
    }
}
