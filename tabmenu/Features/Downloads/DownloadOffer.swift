//
//  DownloadOffer.swift
//  tabmenu
//

import Foundation

/// What the island says about a link it has found.
///
/// A capsule can carry a glyph and two lines, which is enough for "a track changed" and nowhere
/// near enough for "shall I download this". A download is a decision, and a decision needs the
/// things it turns on: what the file is, how big, what quality, and where it came from. So the
/// island stops being a capsule for this one and grows into a card.
nonisolated struct DownloadOffer: Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    /// Where it came from, which is how someone recognises a link they did not expect.
    let host: String
    let symbolName: String
    /// The best thing known about it — "1080p · 9,9 MB", or a size on its own.
    let detail: String?
    let isMedia: Bool
    /// How many qualities were found, so the card can say there is a choice to make.
    let optionCount: Int

    init(candidate: DownloadCandidate, id: UUID = UUID()) {
        self.id = id
        self.title = candidate.displayName
        self.host = candidate.host
        self.symbolName = candidate.transport == .mediaTool || !candidate.streamOptions.isEmpty
            ? "play.rectangle.on.rectangle.fill"
            : candidate.kind.symbolName
        self.isMedia = candidate.transport == .mediaTool || !candidate.streamOptions.isEmpty
        self.optionCount = candidate.streamOptions.count

        if let best = candidate.streamOptions.first {
            self.detail = best.label
        } else if let size = candidate.byteSize {
            self.detail = Format.bytes(size)
        } else {
            self.detail = nil
        }
    }
}
