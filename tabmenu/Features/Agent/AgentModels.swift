//
//  AgentModels.swift
//  MagicPlus
//

import Foundation

/// A JSON value, as itself.
///
/// The agent lives on JSON: tool schemas go out as it, tool arguments come back as it, and three
/// providers each wrap it differently. One enum that *is* JSON — rather than a `[String: Any]`
/// that hopes — means every request body is built from values the compiler has checked, and every
/// response is picked apart with accessors that return `nil` instead of trapping.
nonisolated indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Reading

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        // Providers disagree about whether 0.6 in a schema example comes back as a number or a
        // string, so a number-shaped string counts.
        if case .string(let value) = self { return Double(value) }
        return nil
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// Decoded from data, or `nil` — response parsing wants a question, not a throw.
    static func decoded(from data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// The value as compact JSON text, for tool arguments that travel as strings.
    var jsonText: String {
        guard let data = try? encodedData() else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Parsed from JSON text, tolerating what models actually send.
    ///
    /// Two things they send that the specification does not mention. An empty string, for a call
    /// with no arguments — and `""` is not JSON. And the arguments encoded *twice*: the field holds
    /// a JSON string whose contents are the JSON object, which parses to a string rather than to
    /// arguments, so every argument silently goes missing. Measured on IBM Granite; one extra
    /// unwrap, only when the inside is an object, costs nothing on the models that behave.
    static func parsed(fromText text: String) -> JSONValue {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return .object([:]) }
        guard let value = decoded(from: data) else { return .object([:]) }

        if case .string(let inner) = value,
           let innerData = inner.data(using: .utf8),
           let unwrapped = decoded(from: innerData),
           case .object = unwrapped {
            return unwrapped
        }
        return value
    }
}

// MARK: - The conversation, as the loop sees it

/// One capability the model may call.
nonisolated struct ToolSpec: Sendable {
    let name: String
    let description: String
    /// A JSON Schema object describing the arguments.
    let parameters: JSONValue
}

/// The model asking for a tool to be run.
nonisolated struct ToolCallRequest: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: JSONValue
}

/// What running it produced, tied back to the call by its id.
nonisolated struct ToolResult: Equatable, Sendable {
    let callID: String
    let name: String
    let content: String
}

/// One turn of the conversation, in provider-neutral shape. Each provider maps these onto its own
/// wire format; the loop itself never sees a wire format.
nonisolated enum AgentTurn: Equatable, Sendable {
    case user(String)
    case assistant(text: String?, toolCalls: [ToolCallRequest])
    case toolResults([ToolResult])
}

/// What a round cost, when the provider says.
///
/// Read and shown, because somebody spending their own money on every message should be able to see
/// what a conversation is costing them — and because a measured comparison of seven models found a
/// tenfold spread between them. Providers all report it and this app was throwing it away.
nonisolated struct TokenUsage: Equatable, Sendable {
    var input = 0
    var output = 0

    var total: Int { input + output }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output)
    }

    /// The usage in a reply body, wherever this provider keeps it.
    static func read(from reply: JSONValue) -> TokenUsage? {
        guard let usage = reply["usage"] else { return nil }
        // OpenAI and Cloudflare: prompt/completion. Anthropic: input/output.
        let input = usage["prompt_tokens"]?.numberValue ?? usage["input_tokens"]?.numberValue
        let output = usage["completion_tokens"]?.numberValue ?? usage["output_tokens"]?.numberValue
        guard input != nil || output != nil else { return nil }
        return TokenUsage(input: Int(input ?? 0), output: Int(output ?? 0))
    }
}

/// What a provider round produced: an answer, requests for tools, or both.
nonisolated struct ProviderReply: Equatable, Sendable {
    let text: String?
    let toolCalls: [ToolCallRequest]
    var usage: TokenUsage?
}

// MARK: - What the chat shows

/// One entry in the visible conversation.
///
/// Distinct from `AgentTurn` on purpose: the model's transcript and the person's are different
/// documents. Steps — "searching, found 3" — appear here and are never sent back to the model;
/// tool results go back to the model and are never shown raw.
struct AgentEntry: Identifiable, Equatable {
    /// One tool that ran, in two registers: a line for a person, and the whole exchange for anyone
    /// who wants to know what actually happened.
    ///
    /// The second is not a debugging leftover. This agent acts on somebody's machine, and "what did
    /// it actually pass to that tool" has to be answerable by the person whose machine it is —
    /// today it is answerable only by reading the source.
    struct Step: Equatable {
        let title: String
        let detail: String
        let toolName: String
        let arguments: String
        let output: String
    }

    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        case step(Step)
        case error(String)
    }

    let id = UUID()
    let kind: Kind
    /// Set on the entry that a retry should start from — the message whose answer failed.
    var isRetryable = false
}
