//
//  ModelProvider.swift
//  MagicPlus
//

import Foundation

/// A hosted language model the agent can think with.
///
/// One request-shaped call, deliberately: the agent's loop sends the conversation so far and gets
/// back text, tool calls, or both. Streaming, retries and anything else a provider offers stays
/// behind this line so the loop never grows an `if anthropic`.
nonisolated protocol ModelProvider: Sendable {
    func send(system: String, turns: [AgentTurn], tools: [ToolSpec]) async throws -> ProviderReply

    /// The same call, delivered as it arrives.
    ///
    /// `onDelta` is awaited rather than fired and forgotten, which is what keeps the fragments in
    /// the order they were written — a stream reassembled out of order is worse than no stream.
    func stream(
        system: String,
        turns: [AgentTurn],
        tools: [ToolSpec],
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderReply
}

extension ModelProvider {
    /// A provider that cannot stream still works: the whole answer arrives as one fragment. Nothing
    /// above this line has to know which kind it is talking to.
    func stream(
        system: String,
        turns: [AgentTurn],
        tools: [ToolSpec],
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderReply {
        let reply = try await send(system: system, turns: turns, tools: tools)
        if let text = reply.text, !text.isEmpty { await onDelta(text) }
        return reply
    }
}

/// The providers the settings pane offers.
enum AgentProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAI = "openai"
    case cloudflare

    var id: String { rawValue }

    /// Product names, so none of these localize.
    var title: String {
        switch self {
        case .anthropic: "Claude (Anthropic)"
        case .openAI: "OpenAI"
        case .cloudflare: "Cloudflare Workers AI"
        }
    }

    /// The model used when the field is left empty. Editable precisely because these age.
    var defaultModel: String {
        switch self {
        case .anthropic: "claude-sonnet-5"
        case .openAI: "gpt-5.1"
        // Measured against this app's own toolbox rather than chosen from a spec sheet: it picks
        // the right tool, supplies arguments it had to invent, answers in one round, and costs
        // about a quarter of what the 120b model does. See `AgentModelBenchmark`.
        case .cloudflare: "@cf/zai-org/glm-4.7-flash"
        }
    }
}

/// Why a provider call failed, worded for the chat rather than for a log.
nonisolated enum ProviderError: LocalizedError {
    case missingKey
    case missingAccount
    case badStatus(Int, String)
    case unreadableReply

    var errorDescription: String? {
        switch self {
        case .missingKey:
            String(localized: "No API key is set. Add one in Settings → AI.",
                   comment: "Agent error")
        case .missingAccount:
            String(localized: "Cloudflare needs an account ID. Add it in Settings → AI.",
                   comment: "Agent error")
        case .badStatus(let code, let body):
            String(localized: "The provider answered \(code): \(body)",
                   comment: "Agent error: HTTP status and the provider's own message")
        case .unreadableReply:
            String(localized: "The provider's reply could not be read.",
                   comment: "Agent error")
        }
    }
}

/// Builds the configured provider from preferences and the keychain.
@MainActor
enum ProviderFactory {
    static func make(preferences: Preferences) throws -> any ModelProvider {
        let provider = AgentProvider(rawValue: preferences.agentProvider) ?? .anthropic
        let model = preferences.agentModel.isEmpty ? provider.defaultModel : preferences.agentModel
        guard let key = KeychainStore.read(service: KeychainStore.agentService, account: provider.rawValue),
              !key.isEmpty
        else { throw ProviderError.missingKey }

        switch provider {
        case .anthropic:
            return AnthropicProvider(apiKey: key, model: model)
        case .openAI:
            return OpenAICompatibleProvider(
                endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: key,
                model: model
            )
        case .cloudflare:
            let account = preferences.agentCloudflareAccount.trimmingCharacters(in: .whitespaces)
            guard !account.isEmpty else { throw ProviderError.missingAccount }
            return OpenAICompatibleProvider(
                endpoint: URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/v1/chat/completions")!,
                apiKey: key,
                model: model
            )
        }
    }
}

/// Shared plumbing: one POST with a JSON body, one JSON reply, errors surfaced with the provider's
/// own words — "invalid api key" from the server beats "status 401" from us.
nonisolated enum ProviderHTTP {
    /// The same request, opened as a stream.
    ///
    /// An error body is still JSON, so a failure is read and reported the same way — a streamed
    /// request that fails must not report "the reply could not be read" when the server said
    /// exactly what was wrong.
    static func openStream(
        _ body: JSONValue,
        to url: URL,
        headers: [String: String]
    ) async throws -> URLSession.AsyncBytes {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try body.encodedData()
        request.timeoutInterval = 120

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
                if collected.count > 4096 { break }
            }
            throw ProviderError.badStatus(status, Self.errorMessage(in: collected))
        }
        return bytes
    }

    static func post(
        _ body: JSONValue,
        to url: URL,
        headers: [String: String]
    ) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try body.encodedData()
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.badStatus(status, Self.errorMessage(in: data))
        }
        guard let reply = JSONValue.decoded(from: data) else { throw ProviderError.unreadableReply }
        return reply
    }

    /// The human-readable part of an error body, wherever this provider keeps it.
    static func errorMessage(in data: Data) -> String {
        guard let json = JSONValue.decoded(from: data) else {
            return String(data: data.prefix(200), encoding: .utf8) ?? ""
        }
        // Anthropic: {error:{message}}. OpenAI: {error:{message}}. Cloudflare: {errors:[{message}]}.
        if let message = json["error"]?["message"]?.stringValue { return message }
        if let message = json["errors"]?.arrayValue?.first?["message"]?.stringValue { return message }
        return json.jsonText.prefix(200).description
    }
}
