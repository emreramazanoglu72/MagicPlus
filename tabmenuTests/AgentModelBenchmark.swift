//
//  AgentModelBenchmark.swift
//  tabmenuTests
//

import Testing
import Foundation
@testable import tabmenu

/// Tries candidate models against the real toolbox and reports which ones can actually do the job.
///
/// Disabled by default: it spends money and needs a key. Run with `AGENT_BENCH=1`.
///
/// It exists because a provider's metadata saying `function_calling: true` is a claim about the
/// model, not about the model *with these ten tools and this system prompt*. The only way to know
/// whether a cheap model can drive this assistant is to make it try, twice — once to choose a tool,
/// once to answer from the result — and to count the tokens while it does.
@MainActor
@Suite("Model benchmark", .enabled(if: ProcessInfo.processInfo.environment["AGENT_BENCH"] == "1"))
struct AgentModelBenchmark {
    /// The cheap end of what this account offers, by published price per million tokens.
    private static let candidates = [
        "@cf/ibm-granite/granite-4.0-h-micro",
        "@cf/qwen/qwen3-30b-a3b-fp8",
        "@cf/zai-org/glm-4.7-flash",
        "@cf/google/gemma-4-26b-a4b-it",
        "@cf/openai/gpt-oss-20b",
        "@cf/meta/llama-4-scout-17b-16e-instruct",
        "@cf/openai/gpt-oss-120b"
    ]

    /// Published price per million tokens, so the verdict can be money rather than token counts.
    /// Input and output are billed differently and a chatty model is expensive in the second one.
    private static let price: [String: (input: Double, output: Double)] = [
        "@cf/ibm-granite/granite-4.0-h-micro": (0.017, 0.112),
        "@cf/qwen/qwen3-30b-a3b-fp8": (0.0509, 0.335),
        "@cf/zai-org/glm-4.7-flash": (0.0605, 0.40),
        "@cf/google/gemma-4-26b-a4b-it": (0.10, 0.30),
        "@cf/openai/gpt-oss-20b": (0.20, 0.30),
        "@cf/meta/llama-4-scout-17b-16e-instruct": (0.27, 0.85),
        "@cf/openai/gpt-oss-120b": (0.35, 0.75)
    ]

    /// Two jobs, easy then hard. The first tool takes no arguments at all, which almost anything
    /// can manage; the second has to be given a query it invented from the question, and inventing
    /// arguments is where a small model stops being able to drive this.
    private struct Job {
        let name: String
        let question: String
        let expected: String
    }

    private static let jobs = [
        Job(name: "no-argument tool", question: "How much free disk space do I have?", expected: "system_status"),
        Job(name: "argument tool", question: "Do I have any PDF files? Tell me how many you find.", expected: "search_files")
    ]

    private struct Outcome {
        var calledTool = false
        var toolName = ""
        var arguments = ""
        var answered = false
        var answer = ""
        var input = 0
        var output = 0
        var failure = ""
    }

    @Test func cheapModelsAreTriedAgainstTheRealToolbox() async throws {
        let preferences = Preferences()
        let account = preferences.agentCloudflareAccount
        guard let key = KeychainStore.read(service: KeychainStore.agentService, account: "cloudflare"),
              !key.isEmpty, !account.isEmpty
        else {
            Issue.record("no Cloudflare key or account configured")
            return
        }
        let endpoint = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/v1/chat/completions")!
        let toolbox = AgentToolbox(shelf: ShelfStore(), clipboard: ClipboardService(preferences: preferences))

        for job in Self.jobs {
        print("########## \(job.name): \(job.question)")
        let question = job.question
        for model in Self.candidates {
            var outcome = Outcome()
            do {
                // Round one: the model is asked something only a tool can answer.
                let first = try await Self.post(
                    OpenAICompatibleProvider.requestBody(
                        system: AgentService.systemPrompt(),
                        turns: [.user(question)],
                        tools: AgentToolbox.specs,
                        model: model
                    ),
                    to: endpoint, key: key, input: &outcome.input, output: &outcome.output
                )
                let reply = try OpenAICompatibleProvider.parse(first)
                outcome.calledTool = !reply.toolCalls.isEmpty
                outcome.toolName = reply.toolCalls.map(\.name).joined(separator: ",")
                outcome.arguments = reply.toolCalls.first?.arguments.jsonText ?? ""

                if let call = reply.toolCalls.first {
                    // Round two: the tool actually runs, and its result goes back.
                    let output = await toolbox.run(call)
                    let second = try await Self.post(
                        OpenAICompatibleProvider.requestBody(
                            system: AgentService.systemPrompt(),
                            turns: [
                                .user(question),
                                .assistant(text: reply.text, toolCalls: reply.toolCalls),
                                .toolResults([ToolResult(callID: call.id, name: call.name, content: output)])
                            ],
                            tools: AgentToolbox.specs,
                            model: model
                        ),
                        to: endpoint, key: key, input: &outcome.input, output: &outcome.output
                    )
                    let final = try OpenAICompatibleProvider.parse(second)
                    outcome.answer = (final.text ?? "").replacingOccurrences(of: "\n", with: " ")
                    outcome.answered = !outcome.answer.isEmpty
                }
            } catch {
                outcome.failure = error.localizedDescription
            }

            let right = outcome.toolName == job.expected
            let verdict = outcome.failure.isEmpty
                ? (right && outcome.answered ? "WORKS" : "NO")
                : "ERROR"
            let rate = Self.price[model] ?? (0, 0)
            // What a thousand conversations of this shape would cost.
            let cost = (Double(outcome.input) * rate.input + Double(outcome.output) * rate.output) / 1000
            print("""
            === \(model)
                verdict: \(verdict)  tool: \(outcome.toolName.isEmpty ? "-" : outcome.toolName) \
            \(outcome.arguments)
                tokens: in \(outcome.input) / out \(outcome.output)  ~$\(String(format: "%.3f", cost)) per 1000
                answer: \(outcome.answer.prefix(100))
                \(outcome.failure.isEmpty ? "" : "failure: " + outcome.failure.prefix(160))
            """)
        }
        }
    }

    /// Posts a body and adds the reported token usage to a running total, which is the number that
    /// decides this — correctness first, then what it costs to be correct.
    private static func post(
        _ body: JSONValue,
        to url: URL,
        key: String,
        input: inout Int,
        output: inout Int
    ) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try body.encodedData()
        request.timeoutInterval = 90

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = JSONValue.decoded(from: data) else { throw ProviderError.unreadableReply }
        guard (200..<300).contains(status) else {
            throw ProviderError.badStatus(status, json.jsonText)
        }
        input += Int(json["usage"]?["prompt_tokens"]?.numberValue ?? 0)
        output += Int(json["usage"]?["completion_tokens"]?.numberValue ?? 0)
        return json
    }
}
