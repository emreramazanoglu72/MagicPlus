//
//  AgentLiveCheck.swift
//  tabmenuTests
//

import Testing
import Foundation
@testable import tabmenu

/// One real round trip against whatever is configured, so "it should work" becomes "it does".
///
/// Disabled by default: it spends money and needs a key, which is not what a test suite is for.
/// Run it with `AGENT_LIVE=1` and it uses the provider, model and keychain entry the app is
/// actually set up with.
///
/// Two questions, in order, because the second is only interesting if the first passes: can this
/// key reach this model at all, and will this model *call a tool*? Tool calling is first-class on
/// Claude and OpenAI and varies by model on Workers AI, so it is the thing worth measuring rather
/// than assuming.
@MainActor
@Suite(
    "Live agent check",
    .enabled(if: ProcessInfo.processInfo.environment["AGENT_LIVE"] == "1"),
    // One at a time. Run in parallel these three compete for the same endpoint and one of them
    // times out — which reads as a broken assistant and is a broken test.
    .serialized
)
struct AgentLiveCheck {
    @Test func theConfiguredModelAnswersAndCallsTools() async throws {
        let preferences = Preferences()
        let provider = AgentProvider(rawValue: preferences.agentProvider) ?? .anthropic
        let model = preferences.agentModel.isEmpty ? provider.defaultModel : preferences.agentModel
        print("=== provider: \(provider.rawValue), model: \(model)")

        let client = try ProviderFactory.make(preferences: preferences)

        // 1. Plain text: key, endpoint, model name.
        let hello = try await client.send(
            system: "Answer with one short sentence.",
            turns: [.user("Say hello.")],
            tools: []
        )
        print("=== plain reply: \(hello.text ?? "(none)")")
        #expect(hello.text?.isEmpty == false, "the model answered nothing at all")

        // 2. With tools, and a question that can only be answered by calling one.
        let withTools = try await client.send(
            system: AgentService.systemPrompt(),
            turns: [.user("What is my battery level right now?")],
            tools: AgentToolbox.specs
        )
        print("=== tool calls: \(withTools.toolCalls.map(\.name))")
        print("=== text alongside: \(withTools.text ?? "(none)")")
        // A model that answers a machine question without calling a tool is a model making it up.
        #expect(!withTools.toolCalls.isEmpty, "tool calling is not working on this model")
    }

    /// Streaming, against the real provider: the answer has to arrive in pieces rather than at the
    /// end, and the pieces have to add up to the same answer.
    @Test func theAnswerArrivesInPieces() async throws {
        let preferences = Preferences()
        let client = try ProviderFactory.make(preferences: preferences)

        var fragments: [String] = []
        let start = Date()
        var firstFragmentAt: TimeInterval?

        let reply = try await client.stream(
            system: "Answer in three short sentences.",
            turns: [.user("Describe the sea.")],
            tools: []
        ) { fragment in
            await MainActor.run {
                if firstFragmentAt == nil { firstFragmentAt = Date().timeIntervalSince(start) }
                fragments.append(fragment)
            }
        }

        let total = Date().timeIntervalSince(start)
        print("=== fragments: \(fragments.count)")
        print("=== first after \(String(format: "%.2f", firstFragmentAt ?? -1))s, finished at \(String(format: "%.2f", total))s")
        print("=== joined == reply: \(fragments.joined() == (reply.text ?? ""))")
        print("=== text: \((reply.text ?? "").prefix(120))")

        #expect(fragments.count > 1, "one fragment is not a stream")
        #expect(fragments.joined() == reply.text, "the pieces have to be the whole")
        #expect(try #require(firstFragmentAt) < total, "the first word should arrive before the last")
    }

    /// An answer with code in it, which is what the chat's markdown had to be rebuilt for — and the
    /// token counter, which the app was throwing away.
    @Test func aCodeAnswerArrivesAsBlocksAndIsCounted() async throws {
        let preferences = Preferences()
        let service = AgentService(
            preferences: preferences,
            toolbox: AgentToolbox(shelf: ShelfStore(), clipboard: ClipboardService(preferences: preferences))
        )
        service.send("Show me a bash command that lists files by size, in a fenced code block. No tools.")
        for _ in 0..<1200 {
            if !service.isWorking { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        var sawCode = false
        for entry in service.entries {
            guard case .assistant(let text) = entry.kind else { continue }
            let blocks = ChatMarkdown.blocks(of: text)
            print("--- blocks: \(blocks.count)")
            for block in blocks {
                switch block {
                case .prose(let prose): print("    prose: \(prose.prefix(70))")
                case .code(let code, let language):
                    sawCode = true
                    print("    code[\(language ?? "-")]: \(code.prefix(70))")
                }
            }
        }
        print("--- usage: \(service.usage.input) in / \(service.usage.output) out")
        #expect(service.usage.total > 0, "the provider reports usage and it has to reach the meter")
        #expect(sawCode, "an answer asked for as code should parse as code")
    }

    /// Reading a real file, end to end: the model has to find it, read it, and answer from it.
    @Test func itCanReadAFileAndAnswerFromIt() async throws {
        let preferences = Preferences()
        let service = AgentService(
            preferences: preferences,
            toolbox: AgentToolbox(shelf: ShelfStore(), clipboard: ClipboardService(preferences: preferences))
        )
        var context = AgentContext()
        context.frontmostApplication = "Xcode"
        context.now = Date()
        service.contextReader = { context }

        service.send("~/magicplus-agent-demo.txt dosyasında hangi sürüm numarası geçiyor?")
        for _ in 0..<1200 {
            if !service.isWorking { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        for entry in service.entries {
            switch entry.kind {
            case .user(let text): print("--- you: \(text)")
            case .assistant(let text): print("--- agent: \(text)")
            case .step(let step): print("--- step: \(step.title) — \(step.detail.prefix(60))")
            case .error(let text): print("--- error: \(text)")
            }
        }
        #expect(service.entries.contains { if case .assistant = $0.kind { true } else { false } })
    }

    /// The whole loop against the real provider: ask, run a tool, feed the result back, answer.
    @Test func theLoopCompletesAgainstTheRealProvider() async throws {
        let preferences = Preferences()
        let service = AgentService(
            preferences: preferences,
            toolbox: AgentToolbox(shelf: ShelfStore(), clipboard: ClipboardService(preferences: preferences))
        )
        let started = Date()
        service.send("How much free disk space do I have?")

        // Generous: a reasoning model on a busy endpoint takes its time, and a test that gives up
        // early reports a hang that is really just patience running out.
        for _ in 0..<1200 {
            if !service.isWorking { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("--- took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        for entry in service.entries {
            switch entry.kind {
            case .user(let text): print("--- you: \(text)")
            case .assistant(let text): print("--- agent: \(text)")
            case .step(let step): print("--- step: \(step.title) — \(step.detail)")
            case .error(let text): print("--- error: \(text)")
            }
        }

        #expect(!service.entries.contains { if case .error = $0.kind { true } else { false } })
        #expect(service.entries.contains { if case .assistant = $0.kind { true } else { false } },
                "the loop never produced an answer")
    }
}
