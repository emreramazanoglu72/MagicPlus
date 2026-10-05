//
//  ModelCatalog.swift
//  MagicPlus
//

import Foundation

/// Which models a provider will actually accept.
///
/// Asked of the provider rather than hardcoded, because a list baked into this app is a list that
/// is wrong by the next release — models arrive and retire on their own schedule, and a picker
/// offering something the account cannot call is worse than a text field. The built-in list is the
/// fallback for before a key is set and for when the call fails, not the source of truth.
nonisolated enum ModelCatalog {
    /// Known-good names to offer when the provider cannot be asked. Deliberately short: this is a
    /// starting point somebody can change, not a catalogue.
    static func fallback(for provider: AgentProvider) -> [String] {
        switch provider {
        case .anthropic:
            ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-haiku-4-5-20251001"]
        case .openAI:
            ["gpt-5.1", "gpt-5", "gpt-4.1", "gpt-4o", "gpt-4o-mini"]
        case .cloudflare:
            // Only models measured driving this toolbox end to end, cheapest first. Workers AI
            // lists sixteen that claim tool calling and several of them cannot supply an argument
            // they had to invent, which is most of what this assistant asks for.
            [
                "@cf/zai-org/glm-4.7-flash",
                "@cf/google/gemma-4-26b-a4b-it",
                "@cf/qwen/qwen3-30b-a3b-fp8",
                "@cf/meta/llama-4-scout-17b-16e-instruct",
                "@cf/openai/gpt-oss-120b"
            ]
        }
    }

    /// The models this key can use, or an empty array if the provider could not be asked.
    ///
    /// Failure is silent on purpose: a model list is a convenience, and a settings pane that shows
    /// an error because an optional listing endpoint moved is a settings pane that looks broken
    /// when it is not. The picker falls back and carries on.
    static func fetch(provider: AgentProvider, apiKey: String, account: String) async -> [String] {
        guard let url = listingURL(for: provider, account: account) else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        switch provider {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI, .cloudflare:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let json = JSONValue.decoded(from: data)
        else { return [] }

        return names(in: json, for: provider)
    }

    static func listingURL(for provider: AgentProvider, account: String) -> URL? {
        switch provider {
        case .anthropic:
            URL(string: "https://api.anthropic.com/v1/models?limit=100")
        case .openAI:
            URL(string: "https://api.openai.com/v1/models")
        case .cloudflare:
            {
                let trimmed = account.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return URL(string: "https://api.cloudflare.com/client/v4/accounts/\(trimmed)"
                    + "/ai/models/search?task=Text%20Generation&per_page=100")
            }()
        }
    }

    /// The chat-capable model names in a listing response.
    ///
    /// Three providers, two response shapes, and one of them lists things that are not chat models
    /// at all. Kept apart from the request so it can be tested against a recorded body — which is
    /// the only way to check a parser for an endpoint whose failure mode is an empty picker.
    static func names(in json: JSONValue, for provider: AgentProvider) -> [String] {
        switch provider {
        case .anthropic:
            return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }

        case .openAI:
            return (json["data"]?.arrayValue ?? [])
                .compactMap { $0["id"]?.stringValue }
                .filter(isChatModel)
                .sorted()

        case .cloudflare:
            // Workers AI answers `{result: [{name, ...}]}`, already filtered to text generation by
            // the query — but a model whose name does not look like a path is not one we can call.
            return (json["result"]?.arrayValue ?? [])
                .compactMap { $0["name"]?.stringValue }
                .filter { $0.hasPrefix("@cf/") }
                .sorted()
        }
    }

    /// OpenAI's listing is everything the key can reach: embeddings, speech, images, moderation.
    /// Offering those in a chat picker would mean offering a call that cannot work.
    private static func isChatModel(_ id: String) -> Bool {
        let excluded = [
            "embed", "whisper", "tts", "dall-e", "moderation", "audio", "realtime",
            "image", "search", "similarity", "edit", "davinci", "babbage", "transcribe"
        ]
        let lowercased = id.lowercased()
        guard !excluded.contains(where: lowercased.contains) else { return false }
        return lowercased.hasPrefix("gpt") || lowercased.hasPrefix("o1")
            || lowercased.hasPrefix("o3") || lowercased.hasPrefix("o4")
            || lowercased.hasPrefix("chatgpt")
    }
}
