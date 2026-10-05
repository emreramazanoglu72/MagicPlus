//
//  OpenAICompatibleProvider.swift
//  MagicPlus
//

import Foundation

/// Chat Completions, which is two providers in one: OpenAI serves it at its own address, and
/// Cloudflare Workers AI serves the same format under `/ai/v1/` on an account's URL. The endpoint
/// is the whole difference, so it is a parameter rather than a subclass.
///
/// One wrinkle worth a sentence: tool arguments travel as a JSON *string* here, where Anthropic
/// sends an object. `JSONValue.parsed(fromText:)` and `.jsonText` cross that gap in both
/// directions.
nonisolated struct OpenAICompatibleProvider: ModelProvider {
    let endpoint: URL
    let apiKey: String
    let model: String

    func send(system: String, turns: [AgentTurn], tools: [ToolSpec]) async throws -> ProviderReply {
        let reply = try await ProviderHTTP.post(
            Self.requestBody(system: system, turns: turns, tools: tools, model: model),
            to: endpoint,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
        return try Self.parse(reply)
    }

    func stream(
        system: String,
        turns: [AgentTurn],
        tools: [ToolSpec],
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderReply {
        var body = Self.requestBody(system: system, turns: turns, tools: tools, model: model)
        if case .object(var fields) = body {
            fields["stream"] = .bool(true)
            // Asked for explicitly, because a streamed reply reports no usage otherwise and the
            // meter in the chat would sit at nothing for the whole conversation.
            fields["stream_options"] = .object(["include_usage": .bool(true)])
            body = .object(fields)
        }

        let bytes = try await ProviderHTTP.openStream(
            body,
            to: endpoint,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )

        var accumulator = StreamAccumulator()
        var delivered = 0
        for try await event in SSE.events(from: bytes) {
            OpenAIStream.apply(event, to: &accumulator)
            if accumulator.text.count > delivered {
                let fragment = String(accumulator.text.dropFirst(delivered))
                delivered = accumulator.text.count
                await onDelta(fragment)
            }
        }
        return accumulator.reply()
    }

    // MARK: - Wire format

    static func requestBody(
        system: String,
        turns: [AgentTurn],
        tools: [ToolSpec],
        model: String
    ) -> JSONValue {
        var messages: [JSONValue] = [
            .object(["role": .string("system"), "content": .string(system)])
        ]
        for turn in turns { messages.append(contentsOf: wireMessages(for: turn)) }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages)
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters
                    ])
                ])
            })
        }
        return .object(body)
    }

    /// One turn can be several wire messages: each tool result is its own `role: tool` message.
    private static func wireMessages(for turn: AgentTurn) -> [JSONValue] {
        switch turn {
        case .user(let text):
            return [.object(["role": .string("user"), "content": .string(text)])]

        case .assistant(let text, let calls):
            var message: [String: JSONValue] = ["role": .string("assistant")]
            // An empty string rather than `null` for a turn that is only tool calls. OpenAI takes
            // either; Workers AI validates the field as a string and answers a 400 — "Type mismatch
            // of '/messages/2/content', 'string' not in 'null'" — which fails the second round of
            // every conversation that uses a tool, and only the second round.
            message["content"] = .string(text ?? "")
            if !calls.isEmpty {
                message["tool_calls"] = .array(calls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(call.name),
                            "arguments": .string(call.arguments.jsonText)
                        ])
                    ])
                })
            }
            return [.object(message)]

        case .toolResults(let results):
            return results.map { result in
                .object([
                    "role": .string("tool"),
                    "tool_call_id": .string(result.callID),
                    "content": .string(result.content)
                ])
            }
        }
    }

    static func parse(_ reply: JSONValue) throws -> ProviderReply {
        guard let message = reply["choices"]?.arrayValue?.first?["message"]
        else { throw ProviderError.unreadableReply }

        let calls = (message["tool_calls"]?.arrayValue ?? []).compactMap { call -> ToolCallRequest? in
            guard let id = call["id"]?.stringValue,
                  let name = call["function"]?["name"]?.stringValue
            else { return nil }
            return ToolCallRequest(
                id: id,
                name: name,
                arguments: .parsed(fromText: call["function"]?["arguments"]?.stringValue ?? "")
            )
        }

        let text = message["content"]?.stringValue
        return ProviderReply(
            text: (text?.isEmpty ?? true) ? nil : text,
            toolCalls: calls,
            usage: TokenUsage.read(from: reply)
        )
    }
}
