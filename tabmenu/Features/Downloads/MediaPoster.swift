//
//  MediaPoster.swift
//  tabmenu
//

import AppKit
import Foundation

/// Finds the picture a page uses to represent itself.
///
/// A download prompt for a video that shows a grey icon tells you nothing about what you are
/// about to download; the still frame tells you everything. Two routes, in order of cost: a
/// YouTube address carries its own identifier, so the thumbnail can be named without asking
/// anyone. Everything else is asked once for its `og:image`, which is the tag the whole web
/// already fills in so that links look right when shared.
nonisolated enum MediaPoster {
    /// A poster is decoration. It gets one short attempt and is never waited on.
    private static let timeout: TimeInterval = 6
    /// Enough of a page to hold its `<head>`, and no more.
    private static let markupLimit = 192 * 1024

    // MARK: - Known addresses

    /// The eleven-character identifier YouTube puts in every address it hands out.
    static func youTubeIdentifier(in url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        let candidate: String?
        if bare == "youtu.be" {
            candidate = url.pathComponents.dropFirst().first
        } else if bare.hasSuffix("youtube.com") {
            if url.path() == "/watch" {
                candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value
            } else if ["shorts", "live", "embed"].contains(url.pathComponents.dropFirst().first ?? "") {
                candidate = url.pathComponents.dropFirst(2).first
            } else {
                candidate = nil
            }
        } else {
            candidate = nil
        }

        guard let candidate, candidate.count == 11,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return candidate
    }

    /// Thumbnails for an identifier, best first. The largest is not always generated, so the
    /// smaller one — which always is — follows it.
    static func youTubeThumbnails(for identifier: String) -> [URL] {
        ["maxresdefault", "hqdefault"].compactMap {
            URL(string: "https://i.ytimg.com/vi/\(identifier)/\($0).jpg")
        }
    }

    // MARK: - Markup

    /// The address a page nominates as its own picture.
    ///
    /// `og:image` first, then Twitter's equivalent, and either attribute order — plenty of sites
    /// write `content` before `property`.
    static func posterURL(inMarkup markup: String, relativeTo base: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+(?:property|name)\s*=\s*["'](?:og:image(?::secure_url|:url)?|twitter:image(?::src)?)["'][^>]+content\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+(?:property|name)\s*=\s*["'](?:og:image(?::secure_url|:url)?|twitter:image(?::src)?)["']"#
        ]

        for pattern in patterns {
            guard let match = markup.range(of: pattern, options: [.regularExpression, .caseInsensitive])
            else { continue }
            let tag = String(markup[match])
            guard let value = firstQuotedContent(in: tag) else { continue }
            // Sites write these as absolute, protocol-relative and root-relative alike.
            let address = value.hasPrefix("//") ? "https:" + value : value
            if let url = URL(string: address, relativeTo: base)?.absoluteURL,
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
        }
        return nil
    }

    private static func firstQuotedContent(in tag: String) -> String? {
        guard let range = tag.range(
            of: #"content\s*=\s*["']([^"']+)["']"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let fragment = String(tag[range])
        guard let start = fragment.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let rest = fragment[fragment.index(after: start)...]
        guard let end = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        return String(rest[..<end])
    }

    // MARK: - Fetching

    /// The page's picture, or `nil`. Never throws and never blocks anything that matters.
    static func image(for pageURL: URL, headers: [String: String] = [:]) async -> NSImage? {
        var candidates: [URL] = []
        if let identifier = youTubeIdentifier(in: pageURL) {
            candidates = youTubeThumbnails(for: identifier)
        }
        if candidates.isEmpty, let fromMarkup = await posterURL(ofPageAt: pageURL, headers: headers) {
            candidates = [fromMarkup]
        }

        for candidate in candidates {
            if let image = await load(candidate, headers: headers) { return image }
        }
        return nil
    }

    private static func posterURL(ofPageAt url: URL, headers: [String: String]) async -> URL? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        // Read until the head has surely been seen, then stop — rather than asking for a byte
        // range. A range applies to the *compressed* bytes, so slicing a gzipped page hands back
        // something that cannot be decoded at all, which is how a page with a perfectly good tag
        // came back with nothing.
        guard let (stream, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode)
        else { return nil }

        var markup = Data()
        markup.reserveCapacity(markupLimit)
        do {
            for try await byte in stream {
                markup.append(byte)
                if markup.count >= markupLimit { break }
            }
        } catch {
            guard !markup.isEmpty else { return nil }
        }

        guard let text = String(data: markup, encoding: .utf8)
            ?? String(data: markup, encoding: .isoLatin1)
        else { return nil }

        return posterURL(inMarkup: text, relativeTo: url)
    }

    private static func load(_ url: URL, headers: [String: String]) async -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // Referer matters to sites that will not serve their own images to anyone else.
        if let referer = headers["Referer"] { request.setValue(referer, forHTTPHeaderField: "Referer") }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              // A "thumbnail" that does not exist often answers with a tiny placeholder rather
              // than a 404.
              data.count > 2_048,
              let image = NSImage(data: data)
        else { return nil }
        return image
    }
}
