//
//  AnthropicProvider.swift
//  MagicPlus
//

import Foundation

/// The Messages API, mapped to and from the agent's neutral turns.
///
/// The request and reply builders are plain functions from values to values, and internal rather
/// than private, so the tests can hold the wire format still: a provider whose encoding can only
/// be checked by spending tokens is a provider whose encoding is never checked.
nonisolated struct AnthropicProvider: ModelProvider {
    let apiKey: String
    let model: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func send(system: String, turns: [AgentTurn], tools: [ToolSpec]) async throws -> ProviderReply {
        let reply = try await ProviderHTTP.post(
            Self.requestBody(system: system, turns: turns, tools: tools, model: model),
            to: Self.endpoint,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01"
            ]
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
            body = .object(fields)
        }

        let bytes = try await ProviderHTTP.openStream(
            body,
            to: Self.endpoint,
            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        )

        var accumulator = StreamAccumulator()
        var delivered = 0
        for try await event in SSE.events(from: bytes) {
            AnthropicStream.apply(event, to: &accumulator)
            // Only what is new since the last time, so the view appends rather than redraws.
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
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(2048),
            "system": .string(system),
            "messages": .array(turns.map(message(for:)))
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters
                ])
            })
        }
        return .object(body)
    }

    private static func message(for turn: AgentTurn) -> JSONValue {
        switch turn {
        case .user(let text):
            return .object(["role": .string("user"), "content": .string(text)])

        case .assistant(let text, let calls):
            var blocks: [JSONValue] = []
            if let text, !text.isEmpty {
                blocks.append(.object(["type": .string("text"), "text": .string(text)]))
            }
            for call in calls {
                blocks.append(.object([
                    "type": .string("tool_use"),
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "input": call.arguments
                ]))
            }
            return .object(["role": .string("assistant"), "content": .array(blocks)])

        case .toolResults(let results):
            // Tool results are a *user* message here — that is the API's shape, not a mistake.
            return .object([
                "role": .string("user"),
                "content": .array(results.map { result in
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(result.callID),
                        "content": .string(result.content)
                    ])
                })
            ])
        }
    }

    static func parse(_ reply: JSONValue) throws -> ProviderReply {
        guard let blocks = reply["content"]?.arrayValue else { throw ProviderError.unreadableReply }

        var text = ""
        var calls: [ToolCallRequest] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                text += block["text"]?.stringValue ?? ""
            case "tool_use":
                guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue
                else { continue }
                calls.append(ToolCallRequest(
                    id: id,
                    name: name,
                    arguments: block["input"] ?? .object([:])
                ))
            default:
                break
            }
        }
        return ProviderReply(
            text: text.isEmpty ? nil : text,
            toolCalls: calls,
            usage: TokenUsage.read(from: reply)
        )
    }
}
