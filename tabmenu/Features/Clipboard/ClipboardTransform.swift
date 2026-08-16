//
//  ClipboardTransform.swift
//  tabmenu
//

import Foundation

/// Text rewrites offered on a clipboard entry before pasting it.
///
/// Every case is a pure `String -> String?`, returning `nil` when it does not apply, so the
/// panel can hide transforms that would do nothing to the current entry.
enum ClipboardTransform: String, CaseIterable, Identifiable {
    case trimWhitespace
    case singleLine
    case upperCase
    case lowerCase
    case titleCase
    case formatJSON
    case decodeURL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trimWhitespace: String(localized: "Trim", comment: "Clipboard transform: strip surrounding whitespace")
        case .singleLine: String(localized: "One line", comment: "Clipboard transform: collapse line breaks")
        case .upperCase: String(localized: "UPPER", comment: "Clipboard transform: uppercase")
        case .lowerCase: String(localized: "lower", comment: "Clipboard transform: lowercase")
        case .titleCase: String(localized: "Title", comment: "Clipboard transform: capitalise each word")
        case .formatJSON: String(localized: "JSON", comment: "Clipboard transform: pretty-print JSON")
        case .decodeURL: String(localized: "Decode", comment: "Clipboard transform: percent-decode a URL")
        }
    }

    var symbolName: String {
        switch self {
        case .trimWhitespace: "scissors"
        case .singleLine: "arrow.right.to.line"
        case .upperCase: "textformat.size.larger"
        case .lowerCase: "textformat.size.smaller"
        case .titleCase: "textformat"
        case .formatJSON: "curlybraces"
        case .decodeURL: "percent"
        }
    }

    /// Returns the rewritten text, or `nil` when this transform would leave it unchanged.
    func apply(to text: String) -> String? {
        let result: String?

        switch self {
        case .trimWhitespace:
            result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        case .singleLine:
            result = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

        case .upperCase:
            result = text.uppercased()

        case .lowerCase:
            result = text.lowercased()

        case .titleCase:
            result = text.capitalized

        case .formatJSON:
            result = Self.prettyPrintedJSON(text)

        case .decodeURL:
            result = text.removingPercentEncoding
        }

        guard let result, result != text, !result.isEmpty else { return nil }
        return result
    }

    private static func prettyPrintedJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(data: formatted, encoding: .utf8)
    }

    /// Transforms that would actually change the given text.
    static func applicable(to text: String) -> [ClipboardTransform] {
        allCases.filter { $0.apply(to: text) != nil }
    }
}
