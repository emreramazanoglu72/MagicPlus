//
//  HTTPMessage.swift
//  tabmenu
//

import Foundation

/// One request off the wire.
///
/// Only what the bridge needs: a method, a path, headers and a body. No chunked encoding, no
/// keep-alive, no pipelining — the extension sends one small JSON request per download and
/// waits for one answer, and a parser that handles exactly that is a parser that can be read
/// in one sitting and checked in tests.
nonisolated struct HTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    /// Lowercased names, because header case is not significant and callers should not have to
    /// remember that.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The token from an `Authorization: Bearer <token>` header.
    var bearerToken: String? {
        guard let value = header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    /// The requesting extension's origin, when the browser set one. A page on the open web
    /// cannot forge this, which is what makes it usable as a check.
    var origin: String? { header("origin") }
}

/// What to send back.
nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var body: Data
    var contentType = "application/json"
    /// Echoed back so the extension's `fetch` is allowed to read the answer. Only ever an
    /// extension origin — echoing an arbitrary one would let any page on the web read this.
    var allowedOrigin: String?

    static func json(_ object: [String: Any], status: Int = 200, origin: String? = nil) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(status: status, body: body, allowedOrigin: origin)
    }

    static func error(_ status: Int, _ message: String, origin: String? = nil) -> HTTPResponse {
        json(["error": message], status: status, origin: origin)
    }

    var wireFormat: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // Nothing here is cacheable and nothing here is for a browser tab.
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        if let allowedOrigin {
            head += "Access-Control-Allow-Origin: \(allowedOrigin)\r\n"
            head += "Access-Control-Allow-Headers: authorization, content-type\r\n"
            head += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
            head += "Access-Control-Max-Age: 600\r\n"
        }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        default: "Error"
        }
    }
}

/// Accumulates bytes until a whole request has arrived.
///
/// TCP hands over whatever it has, which is not the same shape as what was sent: a request can
/// arrive in three pieces or two requests in one. This holds the leftovers and answers one
/// question — is there a complete request yet.
nonisolated struct HTTPRequestParser {
    /// A request larger than this is not one of ours. The largest thing the extension sends is
    /// a URL, a file name and a cookie header.
    static let bodyLimit = 128 * 1024
    private static let headerLimit = 32 * 1024

    enum Outcome: Equatable {
        case needsMoreData
        case request(HTTPRequest)
        /// Malformed or oversized: answer and hang up.
        case failure(status: Int, message: String)
    }

    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() -> Outcome {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.headerLimit {
                return .failure(status: 413, message: "headers too large")
            }
            return .needsMoreData
        }

        let headData = buffer[buffer.startIndex..<separator.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else {
            return .failure(status: 400, message: "malformed headers")
        }

        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(status: 400, message: "empty request")
        }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .failure(status: 400, message: "malformed request line")
        }
        let method = String(parts[0]).uppercased()
        // The query is not used by any endpoint, and keeping it out means no route can be
        // reached by two different strings.
        let path = String(String(parts[1]).split(separator: "?").first ?? "")

        var headers: [String: String] = [:]
        for line in lines where line.contains(":") {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            headers[pair[0].lowercased().trimmingCharacters(in: .whitespaces)] =
                pair[1].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= Self.bodyLimit else {
            return .failure(status: 413, message: "body too large")
        }

        let bodyStart = separator.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return .needsMoreData }

        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        return .request(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }
}
