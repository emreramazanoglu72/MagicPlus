//
//  AgentService.swift
//  MagicPlus
//

import Foundation
import Observation

/// The agent's loop: a message goes to the model, the model asks for tools, the tools run, their
/// results go back, and eventually the model answers in words.
///
/// The chat shows every stop on that route as it happens — "searching files… 3 results" — because
/// an agent that disappears for eight seconds and returns an answer is indistinguishable from one
/// that made the answer up. Visible steps are the difference between watching something work and
/// hoping it did.
@MainActor
@Observable
final class AgentService {
    /// What the chat renders.
    private(set) var entries: [AgentEntry] = []
    private(set) var isWorking = false
    /// The bar's style at the moment the panel opened, so the chat wears the same surface.
    var panelStyle = DockStyle()
    /// Files handed to the assistant by dropping them on its button, waiting for an instruction.
    ///
    /// Held rather than turned into text straight away: a dropped file is half a request, and the
    /// half that matters — what to do with it — is still being typed. Shown as chips over the field
    /// so it is plain what is about to travel.
    private(set) var attachments: [URL] = []
    /// What the conversation has cost so far. Kept here rather than in the view because it belongs
    /// to the conversation, and a new conversation starts it again.
    private(set) var usage = TokenUsage()
    /// The message being typed. Here rather than in the view so it survives the panel closing, and
    /// so the panel's key handling can put the last message back into it.
    var draft = ""
    /// Which model answered, for the header. Blank until the first reply.
    private(set) var modelName = ""
    /// Whether the panel should stay open when something else is clicked.
    var isPinned = false

    /// The model's transcript. Separate from `entries` — see `AgentEntry`.
    @ObservationIgnored private var turns: [AgentTurn] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    private let preferences: Preferences
    private let toolbox: AgentToolbox
    /// Injectable so the tests can run the loop against a scripted provider — the loop's order of
    /// operations is the feature, and it must be checkable without an API key.
    private let providerFactory: () throws -> any ModelProvider

    /// The most rounds one message may take. Each round is a paid API call, and a model stuck in a
    /// tool loop should run out of leash rather than out of somebody's credit.
    static let maximumRounds = 6

    /// How many turns of history travel with a message.
    ///
    /// Every round re-sends the whole conversation *plus* about fourteen hundred tokens of tool
    /// schemas, so an unbounded transcript costs quadratically and eventually overruns the model's
    /// context — where the failure is a provider error rather than anything a person can act on. A
    /// window keeps the recent exchange, which is what a follow-up question actually needs.
    nonisolated static let historyLimit = 24

    /// The turns to send: the most recent ones, never cutting a tool call away from its result.
    ///
    /// That last part is not a nicety. Every provider rejects a tool result whose call it cannot
    /// see, and an assistant turn holding calls whose results were dropped is just as invalid — so
    /// a window that lands in the middle of an exchange has to be widened until it does not.
    nonisolated static func window(of turns: [AgentTurn], limit: Int = historyLimit) -> [AgentTurn] {
        guard turns.count > limit else { return turns }

        var start = turns.count - limit
        while start > 0 {
            switch turns[start] {
            // A result with its call left behind, or a call whose results follow: step back over it.
            case .toolResults: start -= 1
            case .assistant(_, let calls) where !calls.isEmpty: start -= 1
            default: return Array(turns[start...])
            }
        }
        return turns
    }

    init(
        preferences: Preferences,
        toolbox: AgentToolbox,
        providerFactory: ((Preferences) -> (() throws -> any ModelProvider))? = nil
    ) {
        self.preferences = preferences
        self.toolbox = toolbox
        self.providerFactory = providerFactory?(preferences)
            ?? { try ProviderFactory.make(preferences: preferences) }
    }

    /// The system prompt: who the agent is and how to behave. In English — models follow English
    /// instructions most reliably — with the reply pinned to the user's own language.
    /// Where the moment's context comes from. Injected so the service does not have to know about
    /// the dock, and so the tests can hold it still.
    @ObservationIgnored var contextReader: (() -> AgentContext)?

    static func systemPrompt(context: AgentContext = AgentContext()) -> String {
        let described = context.describe()
        let preamble = described.isEmpty ? "" : "\n\nRight now:\n\(described)"
        return rules + preamble
    }

    private static var rules: String {
        """
        You are the assistant built into MagicPlus, a macOS menu bar and dock app. You help with \
        this Mac: finding files, opening apps and folders, taking notes, reading system status, \
        managing windows, volume and playback.

        Rules:
        - Use the tools for anything about the machine. Never invent file paths or system readings.
        - What is under "Right now" below is already true; do not call a tool to confirm it.
        - To answer anything about what is *in* a file, read it first.
        - Prefer acting over asking: reasonable defaults, then say what you did.
        - If a tool returns nothing useful, say so plainly. Never pretend an action succeeded.
        - You cannot do anything outside your tools. If asked, say what you can do instead.
        - Keep answers short. This is a small chat panel, not a document.
        - Always answer in the language the user writes in.
        """
    }

    /// Takes files dropped on the assistant's button, without duplicating what is already waiting.
    func attach(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) { attachments.append(url) }
    }

    func detach(_ url: URL) {
        attachments.removeAll { $0 == url }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }

        // The paths travel with the message rather than as a separate turn, so the model reads one
        // request instead of guessing which files an instruction refers to.
        let message = Self.message(trimmed, with: attachments)
        attachments.removeAll()

        entries.append(AgentEntry(kind: .user(trimmed)))
        turns.append(.user(message))
        isWorking = true

        let started = Task { [weak self] in
            await self?.converse()
            guard let self, !Task.isCancelled else { return }
            isWorking = false
        }
        task = started
    }

    /// Stops whatever is in flight, keeping the conversation.
    ///
    /// The provider call is a `URLSession` request and cancellation reaches it, so this is a real
    /// stop rather than an ignored answer. Worth having on its own: a slow model locks the chat for
    /// as long as it takes, and the only way out was starting over, which throws away the exchange
    /// somebody was in the middle of.
    func cancel() {
        guard isWorking else { return }
        task?.cancel()
        task = nil
        isWorking = false
        entries.append(AgentEntry(kind: .step(AgentEntry.Step(
            title: String(localized: "Stopped", comment: "Agent: the request was cancelled"),
            detail: "", toolName: "", arguments: "", output: ""
        ))))
    }

    /// A fresh conversation. The panel offers it; closing the panel does not do it, because coming
    /// back to the answer you asked for is the normal case.
    func reset() {
        task?.cancel()
        task = nil
        isWorking = false
        entries.removeAll()
        turns.removeAll()
        attachments.removeAll()
        usage = TokenUsage()
    }

    /// Asks again, from the last thing that was actually said.
    ///
    /// Everything after the last question is dropped — the half-finished exchange that failed is not
    /// context, it is noise, and sending it back would ask the model to explain its own error.
    func retry() {
        guard !isWorking else { return }
        guard let lastUser = turns.lastIndex(where: { if case .user = $0 { true } else { false } })
        else { return }

        turns.removeSubrange((lastUser + 1)...)
        if let entry = entries.lastIndex(where: { if case .user = $0.kind { true } else { false } }) {
            entries.removeSubrange((entry + 1)...)
        }

        isWorking = true
        task = Task { [weak self] in
            await self?.converse()
            guard let self, !Task.isCancelled else { return }
            isWorking = false
        }
    }

    /// The last thing typed, for the up arrow.
    var lastMessage: String? {
        for entry in entries.reversed() {
            if case .user(let text) = entry.kind { return text }
        }
        return nil
    }

    // MARK: - The loop

    private func converse() async {
        modelName = {
            let chosen = AgentProvider(rawValue: preferences.agentProvider) ?? .anthropic
            return preferences.agentModel.isEmpty ? chosen.defaultModel : preferences.agentModel
        }()

        let provider: any ModelProvider
        do {
            provider = try providerFactory()
        } catch {
            entries.append(AgentEntry(kind: .error(error.localizedDescription), isRetryable: true))
            return
        }

        for _ in 0..<Self.maximumRounds {
            guard !Task.isCancelled else { return }

            // The answer is shown as it is written rather than when it is finished. The entry is
            // created by the first fragment and grown by the rest — a round that turns out to be
            // nothing but tool calls never makes one, so no empty bubble appears and disappears.
            var streamingEntry: UUID?

            let reply: ProviderReply
            do {
                reply = try await provider.stream(
                    system: Self.systemPrompt(context: contextReader?() ?? AgentContext()),
                    turns: Self.window(of: turns),
                    tools: AgentToolbox.specs
                ) { fragment in
                    // Hopped explicitly and awaited, so fragments land in order and on the actor
                    // that owns the entries.
                    await MainActor.run {
                        streamingEntry = self.appendStreamed(fragment, to: streamingEntry)
                    }
                }
            } catch {
                // A cancelled request is not a failure, and `cancel()` has already said so.
                guard !Task.isCancelled else { return }
                entries.append(AgentEntry(kind: .error(error.localizedDescription), isRetryable: true))
                return
            }

            if let round = reply.usage { usage = usage + round }
            turns.append(.assistant(text: reply.text, toolCalls: reply.toolCalls))

            if let text = reply.text, !text.isEmpty {
                if let streamingEntry, let index = entries.firstIndex(where: { $0.id == streamingEntry }) {
                    // The finished text replaces what was streamed: a provider that streams and
                    // then corrects itself should leave the correction on screen, not the draft.
                    entries[index] = AgentEntry(kind: .assistant(text))
                } else {
                    entries.append(AgentEntry(kind: .assistant(text)))
                }
            } else if let streamingEntry {
                // Fragments arrived and the finished reply has no text: keep what was said rather
                // than blanking it.
                _ = streamingEntry
            }

            // No tools requested means the model is done talking — unless it said nothing either,
            // in which case the chat would show the question and then silence, and silence is
            // indistinguishable from a hang. It happens: a reasoning model can spend its whole
            // reply thinking and hand back an empty one.
            guard !reply.toolCalls.isEmpty else {
                if reply.text?.isEmpty ?? true {
                    entries.append(AgentEntry(kind: .error(String(
                        localized: "The model returned an empty reply. Try asking again.",
                        comment: "Agent error: neither text nor a tool call came back"
                    ))))
                }
                return
            }

            var results: [ToolResult] = []
            for call in reply.toolCalls {
                guard !Task.isCancelled else { return }
                let output = await toolbox.run(call)
                results.append(ToolResult(callID: call.id, name: call.name, content: output))
                entries.append(AgentEntry(kind: .step(AgentEntry.Step(
                    title: AgentToolbox.stepTitle(for: call),
                    detail: Self.stepDetail(from: output),
                    toolName: call.name,
                    arguments: call.arguments.jsonText,
                    output: output
                ))))
            }
            turns.append(.toolResults(results))
        }

        // Out of rounds with tools still being requested: stopping is the honest end, and saying
        // so beats a conversation that just goes quiet.
        entries.append(AgentEntry(kind: .error(String(
            localized: "Stopped after \(Self.maximumRounds) rounds of tool use without a final answer.",
            comment: "Agent error: the loop's round limit"
        ))))
    }

    /// Adds a fragment to the answer being written, making the entry if this is the first.
    private func appendStreamed(_ fragment: String, to existing: UUID?) -> UUID {
        if let existing, let index = entries.firstIndex(where: { $0.id == existing }),
           case .assistant(let sofar) = entries[index].kind {
            entries[index] = AgentEntry(kind: .assistant(sofar + fragment))
            return entries[index].id
        }
        let entry = AgentEntry(kind: .assistant(fragment))
        entries.append(entry)
        return entry.id
    }

    /// The message as the model sees it: what was typed, then the files it is about.
    ///
    /// The chat shows only what was typed — the paths are plumbing, and a transcript that repeats a
    /// wall of them back at the person who dropped the files reads like a mistake.
    nonisolated static func message(_ text: String, with attachments: [URL]) -> String {
        guard !attachments.isEmpty else { return text }
        let paths = attachments.map(\.path).joined(separator: "\n")
        return "\(text)\n\nThese files:\n\(paths)"
    }

    /// The first line or so of a tool's output, for the step card. The full output went to the
    /// model; a person wants the gist.
    static func stepDetail(from output: String) -> String {
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        let more = lines.count - 1
        guard more > 0 else { return String(first.prefix(90)) }
        return String(localized: "\(String(first.prefix(70))) and \(more) more",
                      comment: "Agent step detail: first result plus a count")
    }
}
