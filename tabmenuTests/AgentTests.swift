//
//  AgentTests.swift
//  tabmenuTests
//

import Testing
import Foundation
@testable import tabmenu

@Suite("JSON values")
struct JSONValueTests {
    @Test func roundTripsThroughData() throws {
        let value = JSONValue.object([
            "name": .string("search_files"),
            "limit": .number(10),
            "deep": .bool(true),
            "nothing": .null,
            "list": .array([.string("a"), .number(2)])
        ])
        let decoded = try #require(JSONValue.decoded(from: value.encodedData()))
        #expect(decoded == value)
    }

    /// Tool arguments arrive as an object from one provider and as a JSON string from another.
    @Test func parsesArgumentsFromText() {
        let parsed = JSONValue.parsed(fromText: #"{"query":"invoice","limit":3}"#)
        #expect(parsed["query"]?.stringValue == "invoice")
        #expect(parsed["limit"]?.numberValue == 3)
    }

    /// OpenAI sends an empty string for a call that takes no arguments, and `""` is not JSON.
    @Test func anEmptyArgumentStringIsAnEmptyObject() {
        #expect(JSONValue.parsed(fromText: "") == .object([:]))
        #expect(JSONValue.parsed(fromText: "not json") == .object([:]))
    }

    /// Some models encode the arguments twice: a JSON string whose contents are the JSON object.
    /// Parsed literally that is a string, so every argument goes missing without an error anywhere.
    @Test func doublyEncodedArgumentsAreUnwrapped() {
        let doubled = #""{\n  \"kind\": \"pdf\",\n  \"limit\": 10\n}""#
        let parsed = JSONValue.parsed(fromText: doubled)
        #expect(parsed["kind"]?.stringValue == "pdf")
        #expect(parsed["limit"]?.numberValue == 10)
    }

    /// But a string that is genuinely a string stays one — unwrapping everything would turn a
    /// perfectly good text argument into an empty object.
    @Test func aPlainStringArgumentIsLeftAlone() {
        #expect(JSONValue.parsed(fromText: #""just text""#) == .string("just text"))
    }

    /// Schemas say "number" and models sometimes answer with a quoted one anyway.
    @Test func aNumberShapedStringReadsAsANumber() {
        #expect(JSONValue.string("42").numberValue == 42)
        #expect(JSONValue.string("apple").numberValue == nil)
    }
}

@Suite("Anthropic wire format")
struct AnthropicWireTests {
    private let tool = ToolSpec(
        name: "search_files",
        description: "Find files.",
        parameters: .object(["type": .string("object")])
    )

    @Test func toolsCarryTheirSchema() {
        let body = AnthropicProvider.requestBody(
            system: "be helpful", turns: [.user("hi")], tools: [tool], model: "claude-sonnet-5"
        )
        #expect(body["model"]?.stringValue == "claude-sonnet-5")
        #expect(body["system"]?.stringValue == "be helpful")

        let first = body["tools"]?.arrayValue?.first
        #expect(first?["name"]?.stringValue == "search_files")
        #expect(first?["input_schema"] != nil, "the schema has to travel or the model guesses")
    }

    /// Tool results are a *user* message in this API. Getting that wrong is a 400 at runtime and
    /// nothing at compile time, which is exactly what a test is for.
    @Test func toolResultsTravelAsAUserMessage() {
        let body = AnthropicProvider.requestBody(
            system: "",
            turns: [.toolResults([ToolResult(callID: "t1", name: "search_files", content: "one.pdf")])],
            tools: [],
            model: "m"
        )
        let message = body["messages"]?.arrayValue?.first
        #expect(message?["role"]?.stringValue == "user")

        let block = message?["content"]?.arrayValue?.first
        #expect(block?["type"]?.stringValue == "tool_result")
        #expect(block?["tool_use_id"]?.stringValue == "t1")
        #expect(block?["content"]?.stringValue == "one.pdf")
    }

    @Test func readsTextAndToolCallsOutOfAReply() throws {
        let reply = JSONValue.object(["content": .array([
            .object(["type": .string("text"), "text": .string("Looking now.")]),
            .object([
                "type": .string("tool_use"),
                "id": .string("call_1"),
                "name": .string("search_files"),
                "input": .object(["query": .string("invoice")])
            ])
        ])])

        let parsed = try AnthropicProvider.parse(reply)
        #expect(parsed.text == "Looking now.")
        #expect(parsed.toolCalls.count == 1)
        #expect(parsed.toolCalls.first?.name == "search_files")
        #expect(parsed.toolCalls.first?.arguments["query"]?.stringValue == "invoice")
    }
}

@Suite("OpenAI-compatible wire format")
struct OpenAIWireTests {
    @Test func theSystemPromptIsTheFirstMessage() {
        let body = OpenAICompatibleProvider.requestBody(
            system: "be helpful", turns: [.user("hi")], tools: [], model: "gpt-5.1"
        )
        let messages = body["messages"]?.arrayValue
        #expect(messages?.first?["role"]?.stringValue == "system")
        #expect(messages?.first?["content"]?.stringValue == "be helpful")
        #expect(messages?.last?["role"]?.stringValue == "user")
    }

    /// Arguments are an object in this app and a string on this wire, in both directions.
    @Test func argumentsCrossAsText() throws {
        let call = ToolCallRequest(id: "c1", name: "set_volume", arguments: .object(["percent": .number(40)]))
        let body = OpenAICompatibleProvider.requestBody(
            system: "", turns: [.assistant(text: nil, toolCalls: [call])], tools: [], model: "m"
        )
        let text = body["messages"]?.arrayValue?.last?["tool_calls"]?.arrayValue?
            .first?["function"]?["arguments"]?.stringValue
        #expect(try #require(text).contains("\"percent\""))

        let reply = JSONValue.object(["choices": .array([.object(["message": .object([
            "content": .null,
            "tool_calls": .array([.object([
                "id": .string("c1"),
                "function": .object([
                    "name": .string("set_volume"),
                    "arguments": .string(#"{"percent":40}"#)
                ])
            ])])
        ])])])])
        let parsed = try OpenAICompatibleProvider.parse(reply)
        #expect(parsed.toolCalls.first?.arguments["percent"]?.numberValue == 40)
    }

    /// A turn that is only tool calls still carries string content.
    ///
    /// OpenAI accepts `null` there and Cloudflare's Workers AI does not — it validates the field as
    /// a string and answers a 400. That breaks the *second* round of any conversation using a tool
    /// and nothing else, which is the kind of thing that ships.
    @Test func anAssistantTurnWithoutTextStillCarriesStringContent() {
        let call = ToolCallRequest(id: "c1", name: "system_status", arguments: .object([:]))
        let body = OpenAICompatibleProvider.requestBody(
            system: "", turns: [.assistant(text: nil, toolCalls: [call])], tools: [], model: "m"
        )
        let content = body["messages"]?.arrayValue?.last?["content"]
        #expect(content == .string(""), "null content is rejected by at least one provider")
    }

    /// Each result is its own message here, where Anthropic packs them into one.
    @Test func eachToolResultIsItsOwnMessage() {
        let body = OpenAICompatibleProvider.requestBody(
            system: "",
            turns: [.toolResults([
                ToolResult(callID: "a", name: "t", content: "1"),
                ToolResult(callID: "b", name: "t", content: "2")
            ])],
            tools: [],
            model: "m"
        )
        // The system prompt, then one message per result.
        let messages = try! #require(body["messages"]?.arrayValue)
        #expect(messages.count == 3)
        #expect(messages[1]["role"]?.stringValue == "tool")
        #expect(messages[1]["tool_call_id"]?.stringValue == "a")
        #expect(messages[2]["tool_call_id"]?.stringValue == "b")
    }
}

// MARK: - The loop

/// A provider that answers from a script, so the loop can be exercised without an API key. Each
/// call takes the next reply and records what it was sent.
private final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [ProviderReply]
    private(set) var seenTurns: [[AgentTurn]] = []

    init(_ replies: [ProviderReply]) { self.replies = replies }

    var roundCount: Int { lock.withLock { seenTurns.count } }
    var lastTurns: [AgentTurn] { lock.withLock { seenTurns.last ?? [] } }

    func send(system: String, turns: [AgentTurn], tools: [ToolSpec]) async throws -> ProviderReply {
        lock.withLock {
            seenTurns.append(turns)
            guard !replies.isEmpty else { return ProviderReply(text: "done", toolCalls: []) }
            return replies.removeFirst()
        }
    }
}

@MainActor
@Suite("The agent's loop")
struct AgentLoopTests {
    private func makeService(_ replies: [ProviderReply]) -> (AgentService, ScriptedProvider) {
        let defaults = UserDefaults(suiteName: "agent.tests") ?? .standard
        let preferences = Preferences(defaults: defaults)
        let provider = ScriptedProvider(replies)
        let service = AgentService(
            preferences: preferences,
            toolbox: AgentToolbox(shelf: ShelfStore(), clipboard: ClipboardService(preferences: preferences)),
            providerFactory: { _ in { provider } }
        )
        return (service, provider)
    }

    /// Waits for the loop to finish rather than sleeping a guessed interval.
    private func settle(_ service: AgentService) async throws {
        for _ in 0..<200 {
            if !service.isWorking { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the loop never finished")
    }

    @Test func aPlainAnswerEndsTheLoopInOneRound() async throws {
        let (service, provider) = makeService([ProviderReply(text: "Hello.", toolCalls: [])])
        service.send("hi")
        try await settle(service)

        #expect(provider.roundCount == 1, "no tools were asked for, so there is nothing to go back for")
        #expect(service.entries.contains { $0.kind == .user("hi") })
        #expect(service.entries.contains { $0.kind == .assistant("Hello.") })
    }

    /// The shape of the whole feature: ask, run, feed back, answer.
    @Test func aToolCallRunsAndItsResultGoesBackToTheModel() async throws {
        let call = ToolCallRequest(id: "c1", name: "system_status", arguments: .object([:]))
        let (service, provider) = makeService([
            ProviderReply(text: nil, toolCalls: [call]),
            ProviderReply(text: "Battery is fine.", toolCalls: [])
        ])
        service.send("how is the battery?")
        try await settle(service)

        #expect(provider.roundCount == 2)

        // A step was shown for the tool, and it was shown before the answer.
        let stepIndex = service.entries.firstIndex { if case .step = $0.kind { true } else { false } }
        let answerIndex = service.entries.firstIndex { $0.kind == .assistant("Battery is fine.") }
        #expect(stepIndex != nil)
        #expect(answerIndex != nil)
        #expect(try #require(stepIndex) < #require(answerIndex))

        // And the second round carried the result back.
        let sentBack = provider.lastTurns.contains { turn in
            guard case .toolResults(let results) = turn else { return false }
            return results.first?.callID == "c1"
        }
        #expect(sentBack, "a tool whose result never reaches the model is a tool that did nothing")
    }

    /// A model that keeps asking for tools runs out of leash rather than out of somebody's credit.
    @Test func anEndlessToolLoopStopsAtTheRoundLimit() async throws {
        let call = ToolCallRequest(id: "c", name: "system_status", arguments: .object([:]))
        let (service, provider) = makeService(
            Array(repeating: ProviderReply(text: nil, toolCalls: [call]), count: 50)
        )
        service.send("go")
        try await settle(service)

        #expect(provider.roundCount == AgentService.maximumRounds)
        #expect(service.entries.contains { if case .error = $0.kind { true } else { false } },
                "stopping quietly would look like an answer that never came")
    }

    /// A round with no text and no tools would otherwise end the loop without adding anything, so
    /// the chat shows the question and then nothing — which looks exactly like a hang.
    @Test func anEmptyReplyIsSaidOutLoudRatherThanEndingInSilence() async throws {
        let (service, _) = makeService([ProviderReply(text: nil, toolCalls: [])])
        service.send("hi")
        try await settle(service)

        #expect(service.entries.contains { if case .error = $0.kind { true } else { false } })
    }

    @Test func aProviderThatCannotBeBuiltIsReportedRatherThanSwallowed() async throws {
        let defaults = UserDefaults(suiteName: "agent.tests.nokey") ?? .standard
        let preferences = Preferences(defaults: defaults)
        let service = AgentService(
            preferences: preferences,
            toolbox: AgentToolbox(shelf: ShelfStore(), clipboard: ClipboardService(preferences: preferences)),
            providerFactory: { _ in { throw ProviderError.missingKey } }
        )
        service.send("hi")
        try await settle(service)

        #expect(service.entries.contains { if case .error = $0.kind { true } else { false } })
    }

    @Test func startingOverClearsBothTranscripts() async throws {
        let (service, provider) = makeService([ProviderReply(text: "Hello.", toolCalls: [])])
        service.send("hi")
        try await settle(service)
        service.reset()

        #expect(service.entries.isEmpty)

        // The model's transcript is private, so it is checked by what the next round is sent.
        service.send("again")
        try await settle(service)
        #expect(provider.lastTurns.count == 1, "the cleared conversation must not travel with the next one")
    }
}

@Suite("The model catalogue")
struct ModelCatalogTests {
    /// Anthropic answers `{data:[{id}]}` and everything in it is a chat model.
    @Test func readsAnthropicListings() {
        let json = JSONValue.object(["data": .array([
            .object(["id": .string("claude-opus-5"), "display_name": .string("Opus 5")]),
            .object(["id": .string("claude-sonnet-5")])
        ])])
        #expect(ModelCatalog.names(in: json, for: .anthropic) == ["claude-opus-5", "claude-sonnet-5"])
    }

    /// OpenAI answers with everything the key can reach. Offering an embedding model in a chat
    /// picker is offering a call that cannot work.
    @Test func keepsOnlyChatModelsFromOpenAI() {
        let json = JSONValue.object(["data": .array([
            .object(["id": .string("gpt-4o")]),
            .object(["id": .string("text-embedding-3-large")]),
            .object(["id": .string("whisper-1")]),
            .object(["id": .string("dall-e-3")]),
            .object(["id": .string("omni-moderation-latest")]),
            .object(["id": .string("gpt-4o-audio-preview")]),
            .object(["id": .string("o3-mini")])
        ])])
        let names = ModelCatalog.names(in: json, for: .openAI)
        #expect(names == ["gpt-4o", "o3-mini"])
    }

    /// Workers AI answers `{result:[{name}]}`, and a name that is not a model path is not callable.
    @Test func readsCloudflareListings() {
        let json = JSONValue.object(["result": .array([
            .object(["name": .string("@cf/meta/llama-3.1-8b-instruct")]),
            .object(["name": .string("something-else")])
        ])])
        #expect(ModelCatalog.names(in: json, for: .cloudflare) == ["@cf/meta/llama-3.1-8b-instruct"])
    }

    /// A body in a shape nobody expected empties the picker rather than crashing it, and the
    /// fallback list is what the pane shows instead.
    @Test func anUnexpectedBodyYieldsNothingRatherThanFailing() {
        for provider in AgentProvider.allCases {
            #expect(ModelCatalog.names(in: .object(["unexpected": .bool(true)]), for: provider).isEmpty)
            #expect(!ModelCatalog.fallback(for: provider).isEmpty, "\(provider) has nothing to fall back on")
        }
    }

    /// Cloudflare is addressed per account, so without one there is nothing to ask.
    @Test func cloudflareNeedsAnAccountBeforeItCanBeAsked() {
        #expect(ModelCatalog.listingURL(for: .cloudflare, account: "") == nil)
        #expect(ModelCatalog.listingURL(for: .cloudflare, account: "  ") == nil)
        #expect(ModelCatalog.listingURL(for: .cloudflare, account: "abc123") != nil)
        #expect(ModelCatalog.listingURL(for: .anthropic, account: "") != nil, "the others need no account")
    }

    /// The default each provider ships with has to be one it will accept.
    @Test func everyProviderDefaultIsInItsOwnFallbackList() {
        for provider in AgentProvider.allCases {
            #expect(ModelCatalog.fallback(for: provider).contains(provider.defaultModel), "\(provider)")
        }
    }
}

@MainActor
@Suite("Files handed to the assistant")
struct AgentAttachmentTests {
    private func makeService() -> AgentService {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "agent.attach") ?? .standard)
        return AgentService(
            preferences: preferences,
            toolbox: AgentToolbox(shelf: ShelfStore(), clipboard: ClipboardService(preferences: preferences)),
            providerFactory: { _ in { ScriptedProviderStub() } }
        )
    }

    private let a = URL(fileURLWithPath: "/tmp/a.pdf")
    private let b = URL(fileURLWithPath: "/tmp/b.pdf")

    /// A drop is easy to repeat by accident, and the same file twice is the same file.
    @Test func attachingTheSameFileTwiceKeepsOne() {
        let service = makeService()
        service.attach([a, b])
        service.attach([a])
        #expect(service.attachments == [a, b])
    }

    @Test func aFileCanBeTakenBackOff() {
        let service = makeService()
        service.attach([a, b])
        service.detach(a)
        #expect(service.attachments == [b])
    }

    /// The paths travel with the message so the model reads one request; the chat shows only what
    /// was typed, because a transcript repeating a wall of paths back reads like a mistake.
    @Test func thePathsTravelWithTheMessageButNotIntoTheTranscript() {
        let text = AgentService.message("summarise these", with: [a, b])
        #expect(text.contains("summarise these"))
        #expect(text.contains("/tmp/a.pdf"))
        #expect(text.contains("/tmp/b.pdf"))

        #expect(AgentService.message("hello", with: []) == "hello", "no files, no plumbing")
    }

    @Test func sendingClearsWhatWasWaiting() {
        let service = makeService()
        service.attach([a])
        service.send("go")
        #expect(service.attachments.isEmpty, "they have been sent; holding them would send them twice")
    }

    @Test func startingOverDropsThemToo() {
        let service = makeService()
        service.attach([a])
        service.reset()
        #expect(service.attachments.isEmpty)
    }
}

/// A provider that answers nothing, for tests that never get as far as a reply.
private struct ScriptedProviderStub: ModelProvider {
    func send(system: String, turns: [AgentTurn], tools: [ToolSpec]) async throws -> ProviderReply {
        ProviderReply(text: "ok", toolCalls: [])
    }
}

@Suite("Reading a file")
struct AgentFileReaderTests {
    private let home = "/Users/someone"

    /// The policy exists because reading is the one thing here that takes something private and
    /// sends it to somebody else's computer. Its failure mode is not a wrong answer, it is a leak.
    @Test func onlyInsideTheHomeFolder() {
        #expect(AgentFileReader.refusal(for: "/etc/passwd", home: home) == .outsideHome)
        #expect(AgentFileReader.refusal(for: "/Library/Preferences/x.plist", home: home) == .outsideHome)
        #expect(AgentFileReader.refusal(for: "/Users/someone-else/notes.txt", home: home) == .outsideHome,
                "a prefix match is not a containment check")
    }

    /// Models write `~/Documents/notes.txt`, because people do. Read literally, the tilde is an
    /// ordinary folder name and the path lands outside home — which is how a file that was plainly
    /// in the home folder came back "outside the user's home folder".
    @Test func aTildeMeansWhatEverybodyMeansByIt() {
        #expect(AgentFileReader.resolve("~/notes.txt", home: home).path == "\(home)/notes.txt")
        #expect(AgentFileReader.resolve("~", home: home).path == home)
        #expect(AgentFileReader.refusal(for: "~/notes.txt", home: home) == .missing,
                "inside home, so the only thing wrong with it is that it is not there")

        // And it is still only the leading one: a file genuinely called "~" in its name is not a
        // home folder reference.
        #expect(AgentFileReader.resolve("\(home)/a~b.txt", home: home).path == "\(home)/a~b.txt")
    }

    /// A bare name means the home folder, not wherever the process was started. Measured: a model
    /// asked for `notes.txt` was told it was "outside the user's home folder" — true of the path
    /// that was resolved, and about a file nobody meant.
    @Test func aBareNameMeansTheHomeFolder() {
        #expect(AgentFileReader.resolve("notes.txt", home: home).path == "\(home)/notes.txt")
        #expect(AgentFileReader.resolve("Documents/notes.txt", home: home).path
                == "\(home)/Documents/notes.txt")
        #expect(AgentFileReader.refusal(for: "notes.txt", home: home) == .missing,
                "inside home, so the only thing wrong with it is that it is not there")
    }

    /// And a relative path cannot be a way out either.
    @Test func aRelativePathCannotEscape() {
        #expect(AgentFileReader.refusal(for: "../../etc/passwd", home: home) == .outsideHome)
    }

    /// The tilde must not become a way out either.
    @Test func aTildeCannotBeUsedToEscape() {
        #expect(AgentFileReader.refusal(for: "~/../../etc/passwd", home: home) == .outsideHome)
    }

    /// A path is standardized before it is judged, or every check is one `..` away from useless.
    @Test func aPathCannotClimbOutOfHome() {
        #expect(AgentFileReader.refusal(for: "\(home)/Documents/../../../etc/passwd", home: home) == .outsideHome)
        #expect(AgentFileReader.refusal(for: "\(home)/../root/.ssh/id_rsa", home: home) == .outsideHome)
    }

    /// Anything running as the user can read these; the boundary is against *sending* them.
    @Test func credentialsAreRefusedEvenInsideHome() {
        for path in [
            "\(home)/.ssh/id_rsa",
            "\(home)/.aws/credentials",
            "\(home)/Projects/app/.env",
            "\(home)/Library/Keychains/login.keychain-db",
            "\(home)/.gnupg/secring.gpg"
        ] {
            #expect(AgentFileReader.refusal(for: path, home: home) == .secret, "\(path)")
        }
    }

    /// And a refusal says why, because a bare "no" gets the same request again.
    @Test func everyRefusalExplainsItself() {
        let refusals: [AgentFileReader.Refusal] = [
            .missing, .outsideHome, .secret, .tooLarge(90), .unreadableKind("folder")
        ]
        for refusal in refusals {
            #expect(!refusal.message.isEmpty)
        }
        #expect(AgentFileReader.Refusal.tooLarge(90).message.contains("90"))
    }

    /// A model that believes it read the end of a document will answer questions about the end.
    @Test func aCutFileSaysItWasCut() {
        let url = URL(fileURLWithPath: "/tmp/long.txt")
        let long = String(repeating: "a", count: AgentFileReader.characterLimit + 500)

        let trimmed = AgentFileReader.trimmed(long, of: url)
        #expect(trimmed.count < long.count)
        #expect(trimmed.contains("Cut here"))
        #expect(trimmed.contains("long.txt"))

        #expect(AgentFileReader.trimmed("short", of: url) == "short", "nothing to say about a whole file")
    }

    /// The whole point, end to end: a real file comes back as its contents.
    @Test func aTextFileComesBackAsItsText() async throws {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: home).appendingPathComponent("magicplus-read-test.txt")
        try "the quick brown fox".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = await AgentFileReader.read(path: url.path, home: home)
        #expect(text == "the quick brown fox")
    }

    @Test func aFolderIsNotAFile() async {
        let text = await AgentFileReader.read(path: NSHomeDirectory(), home: NSHomeDirectory())
        #expect(text.contains("folder"))
    }
}

@Suite("What the assistant is told without asking")
struct AgentContextTests {
    /// Nothing to say is said as nothing, rather than as an empty heading.
    @Test func anEmptyContextDescribesNothing() {
        #expect(AgentContext().describe().isEmpty)
        #expect(AgentContext().isEmpty)
    }

    @Test func whatIsThereIsNamed() {
        var context = AgentContext()
        context.frontmostApplication = "Xcode"
        context.frontmostWindowTitle = "AgentContext.swift"
        context.nowPlaying = "Weightless — Marconi Union"
        context.battery = "64%, charging"

        let described = context.describe()
        #expect(described.contains("Xcode"))
        #expect(described.contains("AgentContext.swift"))
        #expect(described.contains("Weightless"))
        #expect(described.contains("64%"))
    }

    /// The clipboard is deliberately absent: searching it is something somebody asks for, and this
    /// travels with every message whether it was wanted or not.
    @Test func theClipboardIsNotInIt() {
        var context = AgentContext()
        context.frontmostApplication = "Notes"
        let described = context.describe().lowercased()
        #expect(!described.contains("clipboard"))
        #expect(!described.contains("copied"))
    }

    /// It reaches the model, and an absent context leaves the prompt as it was.
    @Test func theContextIsPartOfThePrompt() {
        var context = AgentContext()
        context.frontmostApplication = "Safari"

        let withContext = AgentService.systemPrompt(context: context)
        #expect(withContext.contains("Safari"))
        #expect(withContext.contains("Right now:"))

        // The heading, not the phrase: one of the rules mentions "Right now" in passing, so a test
        // looking for the words alone passes whether or not the section is actually there.
        #expect(!AgentService.systemPrompt().contains("Right now:"))
    }
}

@Suite("Putting a stream back together")
struct StreamAccumulatorTests {
    /// Text arrives a few characters at a time and has to come out in the order it was written.
    @Test func textFragmentsJoinInOrder() {
        var accumulator = StreamAccumulator()
        for fragment in ["Mer", "haba", " dün", "ya"] { accumulator.appendText(fragment) }
        #expect(accumulator.reply().text == "Merhaba dünya")
    }

    /// The whole reason this is a state machine: a tool call arrives as a name in one event and its
    /// arguments split across several, none of which is valid JSON on its own.
    @Test func argumentsSplitAcrossEventsBecomeOneObject() {
        var accumulator = StreamAccumulator()
        accumulator.beginCall(index: 0, id: "call_1", name: "search_files")
        for fragment in ["{\"que", "ry\": \"fat", "ura\"}"] { accumulator.appendArguments(index: 0, fragment) }

        let reply = accumulator.reply()
        #expect(reply.toolCalls.count == 1)
        #expect(reply.toolCalls.first?.name == "search_files")
        #expect(reply.toolCalls.first?.arguments["query"]?.stringValue == "fatura")
    }

    /// Two calls in one stream must not be merged: the index is the only thing tying a fragment to
    /// the call it belongs to.
    @Test func twoCallsStayApart() {
        var accumulator = StreamAccumulator()
        accumulator.beginCall(index: 0, id: "a", name: "open_app")
        accumulator.beginCall(index: 1, id: "b", name: "set_volume")
        accumulator.appendArguments(index: 1, "{\"percent\":30}")
        accumulator.appendArguments(index: 0, "{\"name\":\"Safari\"}")

        let calls = accumulator.reply().toolCalls
        #expect(calls.map(\.name) == ["open_app", "set_volume"], "and in the provider's order")
        #expect(calls.first?.arguments["name"]?.stringValue == "Safari")
        #expect(calls.last?.arguments["percent"]?.numberValue == 30)
    }

    /// A stream cut off mid-call would otherwise ask for a tool called "", which the loop reports
    /// as unknown rather than as the truncation it is.
    @Test func aNamelessCallIsDropped() {
        var accumulator = StreamAccumulator()
        accumulator.beginCall(index: 0, id: "x", name: nil)
        accumulator.appendArguments(index: 0, "{\"half\":")
        #expect(accumulator.reply().toolCalls.isEmpty)
    }

    /// Usage arrives in pieces too — input at the start, output at the end.
    @Test func usageIsKeptAcrossEvents() {
        var accumulator = StreamAccumulator()
        accumulator.note(TokenUsage(input: 900, output: 0))
        accumulator.note(TokenUsage(input: 0, output: 120))
        #expect(accumulator.reply().usage == TokenUsage(input: 900, output: 120))
    }
}

@Suite("Reading each provider's stream")
struct StreamEventTests {
    @Test func anthropicTextAndToolsAreRead() {
        var accumulator = StreamAccumulator()
        let events: [JSONValue] = [
            .object(["type": .string("content_block_delta"), "index": .number(0),
                     "delta": .object(["text": .string("Bakı")])]),
            .object(["type": .string("content_block_delta"), "index": .number(0),
                     "delta": .object(["text": .string("yorum")])]),
            .object(["type": .string("content_block_start"), "index": .number(1),
                     "content_block": .object([
                        "type": .string("tool_use"), "id": .string("t1"), "name": .string("system_status")
                     ])]),
            .object(["type": .string("content_block_delta"), "index": .number(1),
                     "delta": .object(["partial_json": .string("{}")])]),
            .object(["type": .string("message_delta"),
                     "usage": .object(["output_tokens": .number(40)])])
        ]
        for event in events { AnthropicStream.apply(event, to: &accumulator) }

        let reply = accumulator.reply()
        #expect(reply.text == "Bakıyorum")
        #expect(reply.toolCalls.first?.name == "system_status")
        #expect(reply.usage?.output == 40)
    }

    @Test func openAIDeltasAreRead() {
        var accumulator = StreamAccumulator()
        let events: [JSONValue] = [
            .object(["choices": .array([.object(["delta": .object(["content": .string("Hel")])])])]),
            .object(["choices": .array([.object(["delta": .object(["content": .string("lo")])])])]),
            .object(["choices": .array([.object(["delta": .object([
                "tool_calls": .array([.object([
                    "index": .number(0), "id": .string("c1"),
                    "function": .object(["name": .string("open_app"), "arguments": .string("{\"na")])
                ])])
            ])])])]),
            .object(["choices": .array([.object(["delta": .object([
                "tool_calls": .array([.object([
                    "index": .number(0),
                    "function": .object(["arguments": .string("me\":\"Mail\"}")])
                ])])
            ])])])]),
            .object(["usage": .object(["prompt_tokens": .number(500), "completion_tokens": .number(12)])])
        ]
        for event in events { OpenAIStream.apply(event, to: &accumulator) }

        let reply = accumulator.reply()
        #expect(reply.text == "Hello")
        #expect(reply.toolCalls.first?.arguments["name"]?.stringValue == "Mail")
        #expect(reply.usage == TokenUsage(input: 500, output: 12))
    }

    /// An event in a shape nobody expected changes nothing, rather than losing what came before it.
    @Test func anUnexpectedEventIsIgnored() {
        var accumulator = StreamAccumulator()
        accumulator.appendText("kept")
        OpenAIStream.apply(.object(["something": .bool(true)]), to: &accumulator)
        AnthropicStream.apply(.object(["type": .string("ping")]), to: &accumulator)
        #expect(accumulator.reply().text == "kept")
    }
}

@Suite("Talking to the assistant")
struct VoiceTests {
    /// A shell command read out character by character is noise, and it is the thing these answers
    /// are most likely to contain.
    @Test func codeIsNotReadAloud() {
        let spoken = VoiceOutput.spoken(from: "Run this:\n```bash\nrm -rf /tmp/x\n```\nThat is all.")
        #expect(!spoken.contains("rm -rf"))
        #expect(spoken.contains("Run this"))
        #expect(spoken.contains("That is all"))
        // Something is said in place of the code rather than the code being silently dropped —
        // checked as "there is more here than the prose" because the sentence is localized, and a
        // test looking for an English word fails the moment the app runs in another language.
        #expect(spoken.count > "Run this: That is all.".count,
                "it should say there was code rather than skip it")
    }

    /// Inline markdown is read as its words, not its punctuation.
    @Test func markdownPunctuationIsNotRead() {
        let spoken = VoiceOutput.spoken(from: "**Bold** and `code` and *italic*")
        #expect(!spoken.contains("*"))
        #expect(!spoken.contains("`"))
        #expect(spoken.contains("Bold"))
    }

    @Test func nothingToSayIsSaidAsNothing() {
        #expect(VoiceOutput.spoken(from: "").isEmpty)
        #expect(VoiceOutput.spoken(from: "   ").isEmpty)
    }

    /// The voice follows the answer, not the app: the assistant answers in the language it was
    /// asked in, and Turkish read by an English voice is worse than not reading it.
    @Test func theLanguageOfTheAnswerPicksTheVoice() {
        #expect(VoiceOutput.languageCode(of: "Bugün hava çok güzel ve dışarı çıkmak istiyorum") == "tr")
        #expect(VoiceOutput.languageCode(of: "The weather today is lovely and I want to go out") == "en")
    }

    /// A guess it cannot make is left to the system's default voice — a wrong guess sounds worse
    /// than no guess.
    @Test func anUnguessableStringPicksNoVoice() {
        #expect(VoiceOutput.languageCode(of: "42") == nil)
        #expect(VoiceOutput.languageCode(of: "") == nil)
    }

    /// Dictation follows the app's language where a recogniser exists for it, and falls back to
    /// something every installation has rather than to nothing.
    @Test func dictationPicksALocaleItCanActuallyUse() {
        let turkish = VoiceInput.bestLocale(for: Locale(identifier: "tr"))
        #expect(turkish.identifier.hasPrefix("tr") || turkish.identifier == "en-US")

        // A language nothing recognises falls back rather than failing.
        let invented = VoiceInput.bestLocale(for: Locale(identifier: "zz-ZZ"))
        #expect(invented.identifier == "en-US")
    }
}

@Suite("Chat markdown")
struct ChatMarkdownTests {
    /// The gap this closes: `Text` understands inline markdown and nothing about block structure,
    /// so a fenced block arrived as a paragraph with three backticks in it.
    @Test func aFencedBlockBecomesCode() {
        let blocks = ChatMarkdown.blocks(of: "Run this:\n```bash\nls -la\n```\nThat is all.")
        #expect(blocks == [
            .prose("Run this:"),
            .code("ls -la", language: "bash"),
            .prose("That is all.")
        ])
    }

    @Test func aFenceWithoutALanguageStillWorks() {
        #expect(ChatMarkdown.blocks(of: "```\nplain\n```") == [.code("plain", language: nil)])
    }

    /// An answer cut off mid-block is the common case for a fence that never closes, and half a
    /// code block is still code — not a paragraph full of backticks.
    @Test func anUnterminatedFenceClosesAtTheEnd() {
        #expect(ChatMarkdown.blocks(of: "Here:\n```swift\nlet x = 1") == [
            .prose("Here:"),
            .code("let x = 1", language: "swift")
        ])
    }

    @Test func proseWithNoCodeIsOneBlock() {
        #expect(ChatMarkdown.blocks(of: "just a sentence") == [.prose("just a sentence")])
        #expect(ChatMarkdown.blocks(of: "   ").isEmpty, "whitespace is not a paragraph")
        #expect(ChatMarkdown.blocks(of: "").isEmpty)
    }

    /// Blank lines inside code are part of the code; blank lines around prose are not.
    @Test func blankLinesAreKeptInsideCodeOnly() {
        let blocks = ChatMarkdown.blocks(of: "```\na\n\nb\n```")
        #expect(blocks == [.code("a\n\nb", language: nil)])
    }

    @Test func severalBlocksKeepTheirOrder() {
        let blocks = ChatMarkdown.blocks(of: "one\n```\nA\n```\ntwo\n```\nB\n```")
        #expect(blocks.count == 4)
        #expect(blocks.first == .prose("one"))
        #expect(blocks.last == .code("B", language: nil))
    }
}

@Suite("What a conversation costs")
struct TokenUsageTests {
    /// Two shapes, because Anthropic and OpenAI name the same two numbers differently.
    @Test func bothProvidersAreUnderstood() {
        let openAI = JSONValue.object(["usage": .object([
            "prompt_tokens": .number(120), "completion_tokens": .number(30)
        ])])
        #expect(TokenUsage.read(from: openAI) == TokenUsage(input: 120, output: 30))

        let anthropic = JSONValue.object(["usage": .object([
            "input_tokens": .number(200), "output_tokens": .number(45)
        ])])
        #expect(TokenUsage.read(from: anthropic) == TokenUsage(input: 200, output: 45))
    }

    /// A provider that says nothing is not a conversation that cost nothing — showing a zero would
    /// be a claim, so there is no number rather than a wrong one.
    @Test func silenceIsNotZero() {
        #expect(TokenUsage.read(from: .object([:])) == nil)
        #expect(TokenUsage.read(from: .object(["usage": .object([:])])) == nil)
    }

    @Test func roundsAddUp() {
        let total = TokenUsage(input: 100, output: 20) + TokenUsage(input: 150, output: 35)
        #expect(total == TokenUsage(input: 250, output: 55))
        #expect(total.total == 305)
    }
}

@Suite("The conversation window")
struct AgentHistoryWindowTests {
    private func call(_ id: String) -> ToolCallRequest {
        ToolCallRequest(id: id, name: "system_status", arguments: .object([:]))
    }

    @Test func aShortConversationTravelsWhole() {
        let turns: [AgentTurn] = [.user("a"), .assistant(text: "b", toolCalls: [])]
        #expect(AgentService.window(of: turns, limit: 10).count == 2)
    }

    @Test func aLongOneKeepsTheRecentEnd() {
        let turns: [AgentTurn] = (0..<20).map { .user("\($0)") }
        let windowed = AgentService.window(of: turns, limit: 6)
        #expect(windowed.count == 6)
        #expect(windowed.first == .user("14"), "the window has to be the recent end, not the old one")
        #expect(windowed.last == .user("19"))
    }

    /// The part that is not a nicety: every provider rejects a tool result whose call it cannot see.
    /// A window landing mid-exchange has to widen until it holds the whole thing.
    @Test func aWindowNeverSeparatesAToolCallFromItsResult() {
        let turns: [AgentTurn] = [
            .user("old"),
            .user("q"),
            .assistant(text: nil, toolCalls: [call("c1")]),
            .toolResults([ToolResult(callID: "c1", name: "system_status", content: "ok")]),
            .assistant(text: "answer", toolCalls: [])
        ]
        // A limit of 2 would cut between the call and its result.
        let windowed = AgentService.window(of: turns, limit: 2)

        // The invariant rather than an index: every result in the window has its call in the window.
        // Written the other way round first, expecting the window to start at the assistant turn —
        // and it starts one earlier, at the question that prompted it, which is more context rather
        // than less. The test was wrong; this is what actually has to hold.
        for turn in windowed {
            guard case .toolResults(let results) = turn else { continue }
            for result in results {
                let callIsPresent = windowed.contains { candidate in
                    guard case .assistant(_, let calls) = candidate else { return false }
                    return calls.contains { $0.id == result.callID }
                }
                #expect(callIsPresent, "result \(result.callID) travelled without its call")
            }
        }
        #expect(windowed.count == 4)
        #expect(windowed.first == .user("q"), "and it widened past the old turn, not into it")
    }

    /// And when widening runs out of room, everything travels rather than something invalid.
    @Test func aConversationThatIsAllOneExchangeIsNotCut() {
        let turns: [AgentTurn] = [
            .assistant(text: nil, toolCalls: [call("c1")]),
            .toolResults([ToolResult(callID: "c1", name: "system_status", content: "ok")])
        ]
        #expect(AgentService.window(of: turns, limit: 1).count == 2)
    }
}

@Suite("The agent's tools")
struct AgentToolTests {
    /// Every tool the model is told about has to be one the toolbox actually runs. A name in the
    /// catalogue with no case behind it is a promise the model will take up and nothing will keep.
    @MainActor
    @Test func everyAdvertisedToolIsImplemented() async {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "agent.tools") ?? .standard)
        let toolbox = AgentToolbox(shelf: ShelfStore(), clipboard: ClipboardService(preferences: preferences))

        for spec in AgentToolbox.specs {
            // Deliberately no arguments: a tool that needs some should say so, not fall through to
            // the unknown-tool branch.
            let output = await toolbox.run(
                ToolCallRequest(id: "t", name: spec.name, arguments: .object([:]))
            )
            #expect(!output.hasPrefix("Unknown tool"), "\(spec.name) is offered but not implemented")
        }
    }

    @Test func everyToolHasAnObjectSchema() {
        for spec in AgentToolbox.specs {
            #expect(spec.parameters["type"]?.stringValue == "object", "\(spec.name)")
            #expect(spec.parameters["properties"] != nil, "\(spec.name)")
            #expect(!spec.description.isEmpty, "\(spec.name) has nothing to tell the model")
        }
    }

    /// A model-supplied query is data, and a quote in it must not end the predicate early.
    @Test func spotlightQueriesCannotBeBrokenOutOf() {
        let query = SpotlightSearch.query(for: .name("say \"hello\" \\ now"), kind: "any")
        let quotes = query.filter { $0 == "\"" }.count
        #expect(quotes == 2, "the only quotes left should be the ones wrapping the term")
        #expect(!query.contains("\\"))
    }

    @Test func aKindBecomesAContentTypeFilter() {
        #expect(SpotlightSearch.query(for: .name("x"), kind: "pdf").contains("com.adobe.pdf"))
        #expect(!SpotlightSearch.query(for: .name("x"), kind: "any").contains("ContentTypeTree"))
    }

    /// The step card shows the gist; the model gets the whole thing.
    @Test func stepDetailSummarisesWithoutLying() {
        #expect(AgentService.stepDetail(from: "") == "")
        #expect(AgentService.stepDetail(from: "one line") == "one line")

        let many = AgentService.stepDetail(from: "a.pdf\nb.pdf\nc.pdf")
        #expect(many.contains("a.pdf"))
        #expect(many.contains("2"), "the count of what is not shown has to be in there")
    }
}
