//
//  SensitiveContentDetector.swift
//  tabmenu
//

import Foundation

/// Heuristics for things that should never sit in a clipboard history: card numbers, API
/// keys, private keys, tokens. Detection errs towards precision — a false positive silently
/// loses an entry the user expected to find later.
nonisolated enum SensitiveContentDetector {
    /// Prefixes used by well-known credential formats.
    private static let secretPrefixes = [
        "sk-", "sk_live_", "sk_test_",             // OpenAI, Stripe
        "ghp_", "gho_", "github_pat_",             // GitHub
        "xoxb-", "xoxp-", "xoxa-", "xoxs-",        // Slack
        "AKIA", "ASIA",                            // AWS access keys
        "AIza",                                    // Google API
        "glpat-",                                  // GitLab
        "-----BEGIN"                               // PEM private keys / certificates
    ]

    /// Every rule below is a linear scan; 64 KB comfortably covers pasted .env dumps and
    /// config files while keeping the cost per clipboard change negligible.
    private static let maximumScanLength = 65_536

    /// A prefix alone is prose; a real key carries a long random remainder after it.
    private static let minimumSecretSuffixLength = 10

    /// Real JWTs run well past this — header, payload and an HS256 signature already do.
    private static let minimumEmbeddedJWTLength = 60

    static func looksSensitive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // PEM private keys are routinely larger than any cap (a 4096-bit RSA key alone
        // tops 3 KB), so this containment check runs on the full text.
        if containsPrivateKeyBlock(trimmed) { return true }

        guard trimmed.count <= maximumScanLength else { return false }

        if hasSecretPrefix(trimmed) { return true }
        if isPaymentCardNumber(trimmed) { return true }
        if isJSONWebToken(trimmed) { return true }
        return containsSensitiveToken(trimmed)
    }

    // MARK: - Individual rules

    private static func containsPrivateKeyBlock(_ text: String) -> Bool {
        text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----")
    }

    private static func hasSecretPrefix(_ text: String) -> Bool {
        // A key is copied alone; prose that merely mentions one is not a secret.
        guard !text.contains(" ") || text.hasPrefix("-----BEGIN") else { return false }
        return secretPrefixes.contains { text.hasPrefix($0) }
    }

    /// Catches secrets embedded in larger copies — `KEY=sk-…` env lines, `Bearer eyJ…`
    /// headers — while a bare prefix mentioned in prose stays untouched: a token only
    /// counts when a long key-shaped remainder follows the prefix.
    private static func containsSensitiveToken(_ text: String) -> Bool {
        let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`"))
        for token in text.components(separatedBy: delimiters) {
            if isSecretToken(token[...]) { return true }
            // Env-style assignments hide the secret after the '='.
            if let equals = token.firstIndex(of: "="),
               isSecretToken(token[token.index(after: equals)...]) {
                return true
            }
        }
        return false
    }

    private static func isSecretToken(_ token: Substring) -> Bool {
        if token.count >= minimumEmbeddedJWTLength, isJSONWebToken(token) { return true }
        return secretPrefixes.contains { prefix in
            guard token.hasPrefix(prefix) else { return false }
            let suffix = token.dropFirst(prefix.count)
            return suffix.count >= minimumSecretSuffixLength && suffix.allSatisfy(isKeyCharacter)
        }
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }

    /// 13–19 digits (spaces and dashes allowed) that pass the Luhn checksum.
    static func isPaymentCardNumber(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard (13...19).contains(stripped.count),
              stripped.allSatisfy(\.isNumber)
        else { return false }
        return passesLuhn(stripped)
    }

    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    /// Three base64url segments, the first decoding to a JSON header (always starts "eyJ").
    private static func isJSONWebToken(_ text: some StringProtocol) -> Bool {
        guard text.hasPrefix("eyJ"), !text.contains(" ") else { return false }
        let segments = text.split(separator: ".")
        guard segments.count == 3 else { return false }
        let base64url = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        return segments.allSatisfy { segment in
            segment.unicodeScalars.allSatisfy(base64url.contains)
        }
    }
}
