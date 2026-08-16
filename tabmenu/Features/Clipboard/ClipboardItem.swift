//
//  ClipboardItem.swift
//  tabmenu
//

import AppKit

struct ClipboardItem: Identifiable, Codable, Hashable {
    enum Content: Codable, Hashable {
        case text(String)
        case fileURLs([URL])
        /// Images live next to the history file; only the file name is persisted inline.
        case image(fileName: String, pixelSize: CGSize)
    }

    let id: UUID
    let createdAt: Date
    let content: Content
    let sourceBundleID: String?
    let sourceAppName: String?
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        content: Content,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.content = content
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.isPinned = isPinned
    }

    // MARK: - Presentation

    var title: String {
        switch content {
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.replacingOccurrences(of: "\n", with: " ⏎ ")
        case .fileURLs(let urls):
            guard let first = urls.first else {
                return String(localized: "Files", comment: "Clipboard entry holding files")
            }
            guard urls.count > 1 else { return first.lastPathComponent }
            return String(
                localized: "\(first.lastPathComponent) +\(urls.count - 1)",
                comment: "Multiple copied files: first file name, then how many more"
            )
        case .image(_, let size):
            return String(
                localized: "Image \(Int(size.width))×\(Int(size.height))",
                comment: "Copied image with its pixel dimensions"
            )
        }
    }

    var detail: String {
        switch content {
        case .text(let value):
            return String(localized: "\(value.count) characters", comment: "Length of copied text")
        case .fileURLs(let urls):
            guard urls.count > 1 else { return urls.first?.deletingLastPathComponent().path ?? "" }
            return String(localized: "\(urls.count) files", comment: "How many files were copied")
        case .image:
            return String(localized: "Image", comment: "Clipboard entry kind")
        }
    }

    var symbolName: String {
        switch content {
        case .text(let value):
            URL(string: value)?.scheme?.hasPrefix("http") == true ? "link" : "text.alignleft"
        case .fileURLs: "doc"
        case .image: "photo"
        }
    }

    /// Everything the search field matches against: content, file names, and source app.
    var searchText: String {
        var parts: [String] = [sourceAppName ?? ""]
        switch content {
        case .text(let value): parts.append(value)
        case .fileURLs(let urls): parts.append(contentsOf: urls.map(\.path))
        case .image(let fileName, _): parts.append(contentsOf: ["image", fileName])
        }
        return parts.joined(separator: " ")
    }

    /// Identifies duplicate captures so repeated copies move an entry up instead of cloning it.
    var fingerprint: String {
        switch content {
        case .text(let value): "text:\(value)"
        case .fileURLs(let urls): "files:\(urls.map(\.absoluteString).joined(separator: "|"))"
        case .image(let fileName, _): "image:\(fileName)"
        }
    }

    var plainText: String? {
        if case .text(let value) = content { return value }
        return nil
    }
}
