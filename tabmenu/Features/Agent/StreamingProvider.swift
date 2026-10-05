//
//  StreamingProvider.swift
//  MagicPlus
//

import Foundation

/// Reading a server-sent-event stream, and putting one back together.
///
/// Both APIs stream the same way — a line of `data: {…}` per fragment — and both fragment a reply
/// into pieces that mean nothing on their own. Text arrives a few characters at a time; a tool call
/// arrives as a name in one event and its arguments split across a dozen more, none of which is
/// valid JSON by itself. The whole difficulty is in the reassembly, so the reassembly is a pure
/// state machine kept apart from the network and tested against recorded events: a dropped fragment
/// is a tool called with half its arguments, and nothing about that looks like an error.
nonisolated enum SSE {
    /// The payloads of a stream, one per `data:` line, with the terminator dropped.
    static func events(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        // OpenAI ends with a literal sentinel; Anthropic just stops.
                        guard payload != "[DONE]" else { break }
                        guard let value = JSONValue.decoded(from: Data(payload.utf8)) else { continue }
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Builds one reply out of a stream's fragments.
///
/// Shared by both providers because both have the same problem: text in order, tool calls keyed by
/// position, arguments as a string that is only valid JSON once it is all there.
nonisolated struct StreamAccumulator {
    private(set) var text = ""
    private(set) var usage: TokenUsage?
    /// Tool calls by the index the provider gives them, because that is the only thing tying a
    /// fragment to the call it belongs to.
    private var calls: [Int: PartialCall] = [:]

    private struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    mutating func appendText(_ fragment: String) {
        text += fragment
    }

    mutating func note(_ usage: TokenUsage) {
        // Providers send usage in pieces too: input once at the start, output at the end.
        let existing = self.usage ?? TokenUsage()
        self.usage = TokenUsage(
            input: max(existing.input, usage.input),
            output: max(existing.output, usage.output)
        )
    }

    mutating func beginCall(index: Int, id: String?, name: String?) {
        var call = calls[index] ?? PartialCall()
        if let id, !id.isEmpty { call.id = id }
        if let name, !name.isEmpty { call.name = name }
        calls[index] = call
    }

    mutating func appendArguments(index: Int, _ fragment: String) {
        var call = calls[index] ?? PartialCall()
        call.arguments += fragment
        calls[index] = call
    }

    /// The finished reply.
    ///
    /// A call with no name never happened — a stream cut off mid-call would otherwise produce a
    /// request to run a tool called "", which the loop would report as unknown rather than as the
    /// truncation it is.
    func reply() -> ProviderReply {
        let requests = calls
            .sorted { $0.key < $1.key }
            .compactMap { index, call -> ToolCallRequest? in
                guard !call.name.isEmpty else { return nil }
                return ToolCallRequest(
                    // Anthropic always names an id; some OpenAI-compatible servers do not.
                    id: call.id.isEmpty ? "call_\(index)" : call.id,
                    name: call.name,
                    arguments: .parsed(fromText: call.arguments)
                )
            }
        return ProviderReply(
            text: text.isEmpty ? nil : text,
            toolCalls: requests,
            usage: usage
        )
    }
}

// MARK: - Reading each provider's events

nonisolated enum AnthropicStream {
    /// Folds one event into the accumulator.
    static func apply(_ event: JSONValue, to accumulator: inout StreamAccumulator) {
        switch event["type"]?.stringValue {
        case "content_block_start":
            guard let index = event["index"]?.numberValue,
                  let block = event["content_block"],
                  block["type"]?.stringValue == "tool_use"
            else { return }
            accumulator.beginCall(
                index: Int(index),
                id: block["id"]?.stringValue,
                name: block["name"]?.stringValue
            )

        case "content_block_delta":
            guard let delta = event["delta"] else { return }
            if let fragment = delta["text"]?.stringValue {
                accumulator.appendText(fragment)
            }
            if let partial = delta["partial_json"]?.stringValue,
               let index = event["index"]?.numberValue {
                accumulator.appendArguments(index: Int(index), partial)
            }

        case "message_start":
            if let usage = event["message"].flatMap({ TokenUsage.read(from: $0) }) {
                accumulator.note(usage)
            }

        case "message_delta":
            if let usage = TokenUsage.read(from: event) { accumulator.note(usage) }

        default:
            break
        }
    }
}

nonisolated enum OpenAIStream {
    static func apply(_ event: JSONValue, to accumulator: inout StreamAccumulator) {
        if let usage = TokenUsage.read(from: event) { accumulator.note(usage) }

        guard let delta = event["choices"]?.arrayValue?.first?["delta"] else { return }

        if let fragment = delta["content"]?.stringValue, !fragment.isEmpty {
            accumulator.appendText(fragment)
        }

        for (position, call) in (delta["tool_calls"]?.arrayValue ?? []).enumerated() {
            // The index is the provider's, and only falls back to position when it is absent —
            // two calls in one event would otherwise be merged into one.
            let index = Int(call["index"]?.numberValue ?? Double(position))
            accumulator.beginCall(
                index: index,
                id: call["id"]?.stringValue,
                name: call["function"]?["name"]?.stringValue
            )
            if let fragment = call["function"]?["arguments"]?.stringValue, !fragment.isEmpty {
                accumulator.appendArguments(index: index, fragment)
            }
        }
    }
}
