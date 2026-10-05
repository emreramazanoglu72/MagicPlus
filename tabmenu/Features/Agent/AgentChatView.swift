//
//  AgentChatView.swift
//  MagicPlus
//

import SwiftUI

/// The conversation: messages, the steps the agent takes between them, and a field to type in.
///
/// Drawn in the strip's language — the same glass, the same darker bands top and bottom — because
/// it opens out of the strip and should read as part of it. Steps get small cards rather than chat
/// bubbles: they are the agent's work shown honestly, not something anybody said.
struct AgentChatView: View {
    @Bindable var service: AgentService

    @FocusState private var inputFocused: Bool

    /// Speaking and listening. Held by the view rather than the service because they belong to this
    /// panel being open, not to the conversation — a closed chat should not still be talking.
    @State private var voiceIn = VoiceInput()
    @State private var voiceOut = VoiceOutput()

    private var style: DockStyle { service.panelStyle }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
            meter
            attachments
            voiceProblem
            input
        }
        .background { surface }
        .environment(\.colorScheme, style.contentScheme ?? .dark)
        .onAppear { inputFocused = true }
        .onDisappear {
            // A panel that is gone should not still be listening or talking.
            voiceIn.stop()
            voiceOut.stop()
        }
        // What is heard goes into the field, never straight out to the model: recognition
        // mis-hears, and this assistant acts on the machine.
        .onChange(of: voiceIn.transcript) { _, heard in
            guard !heard.isEmpty else { return }
            service.draft = heard
        }
    }

    @ViewBuilder
    private var surface: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill((style.tint ?? .black).opacity(min(1, style.backgroundOpacity + 0.2)))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: -1) {
                Text("Assistant", comment: "Agent panel title")
                    .font(.system(size: 13, weight: .semibold))
                // Which model answered. Two models can give very different answers to the same
                // question, and knowing which one this was is half of judging the answer.
                if !service.modelName.isEmpty {
                    Text(shortModelName)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(service.modelName)
                }
            }

            Spacer()

            // Pinned, it stays put when something else is clicked. Without this the panel closes
            // the moment you turn to the thing you asked about, which is most of what it is for.
            HeaderIcon(
                symbol: service.isPinned ? "pin.fill" : "pin",
                isActive: service.isPinned,
                help: service.isPinned
                    ? String(localized: "Unpin", comment: "Agent panel")
                    : String(localized: "Keep open", comment: "Agent panel")
            ) {
                service.isPinned.toggle()
            }

            if !service.entries.isEmpty {
                HeaderIcon(
                    symbol: "square.and.pencil",
                    isActive: false,
                    help: String(localized: "New conversation", comment: "Agent panel")
                ) {
                    service.reset()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.14))
    }

    /// The tail of a model identifier, which is the part that distinguishes one from another —
    /// `@cf/zai-org/glm-4.7-flash` is mostly a path.
    private var shortModelName: String {
        service.modelName.components(separatedBy: "/").last ?? service.modelName
    }

    // MARK: - Conversation

    @ViewBuilder
    private var conversation: some View {
        if service.entries.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(service.entries) { entry in
                            row(for: entry).id(entry.id)
                        }
                        if service.isWorking { thinking.id("thinking") }
                    }
                    .padding(12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: service.entries.count) {
                    guard let last = service.entries.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// What the agent can do, said with examples — an empty chat that just says "ask me anything"
    /// teaches nothing. Clicking one asks it.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
            Text("Ask about this Mac", comment: "Agent panel: empty state title")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
            Text("It can search your files, open apps, take notes, manage windows and volume.",
                 comment: "Agent panel: empty state summary")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Spacer()

            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    service.send(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.primary.opacity(0.08))
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    private static let suggestions: [String] = [
        String(localized: "Find my most recent PDF", comment: "Agent suggestion"),
        String(localized: "How is the battery and disk doing?", comment: "Agent suggestion"),
        String(localized: "Note down: ", comment: "Agent suggestion — intentionally open-ended")
    ]

    @ViewBuilder
    private func row(for entry: AgentEntry) -> some View {
        switch entry.kind {
        case .user(let text):
            Text(text)
                .font(.system(size: 12.5))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.3))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant(let text):
            AssistantMessage(
                text: text,
                isSpeaking: voiceOut.speakingEntryID == entry.id,
                onSpeak: { voiceOut.toggle(text, id: entry.id) }
            )

        case .step(let step):
            StepCard(step: step)

        case .error(let text):
            VStack(alignment: .leading, spacing: 5) {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                // Asking again should not mean typing it again.
                if entry.isRetryable, !service.isWorking {
                    Button {
                        service.retry()
                    } label: {
                        Label(
                            String(localized: "Try again", comment: "Agent: retry a failed request"),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var thinking: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Working…", comment: "Agent panel: the model is thinking")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Input

    /// The files waiting for an instruction, each removable — a drop is easy to make by accident.
    @ViewBuilder
    private var attachments: some View {
        if !service.attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(service.attachments, id: \.self) { url in
                        HStack(spacing: 4) {
                            Image(systemName: "doc")
                                .font(.system(size: 9))
                            Text(url.lastPathComponent)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                            Button {
                                service.detach(url)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background {
                            Capsule().fill(.primary.opacity(0.10))
                        }
                        .help(url.path)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: 30)
            .background(.black.opacity(0.14))
        }
    }

    /// What the conversation has cost. Absent until there is something to say, so an empty chat is
    /// not decorated with a zero.
    @ViewBuilder
    private var meter: some View {
        if service.usage.total > 0 {
            HStack(spacing: 4) {
                Spacer()
                Text("\(service.usage.total) tokens", comment: "Agent: what the conversation has used")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(String(
                        localized: "\(service.usage.input) in, \(service.usage.output) out",
                        comment: "Agent: token usage split"
                    ))
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
    }

    private var input: some View {
        HStack(spacing: 8) {
            if VoiceInput.isAvailable() {
                DictationButton(voice: voiceIn) {
                    voiceIn.toggle()
                    if voiceIn.isListening { inputFocused = true }
                }
            }

            TextField(placeholder, text: $service.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(1...4)
            .focused($inputFocused)
            .onSubmit(sendDraft)

            // While something is in flight the same place is a stop button, because that is where
            // the hand already is and waiting is the state you want to leave.
            Button {
                service.isWorking ? service.cancel() : sendDraft()
            } label: {
                Image(systemName: service.isWorking ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(buttonTint)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!service.isWorking && !canSend)
            .help(service.isWorking
                  ? String(localized: "Stop", comment: "Agent: cancel the request in flight")
                  : String(localized: "Send", comment: "Agent: send the message"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.14))
    }

    private var buttonTint: AnyShapeStyle {
        if service.isWorking { return AnyShapeStyle(.orange) }
        return canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
    }

    @ViewBuilder
    private var voiceProblem: some View {
        if case .failed(let message) = voiceIn.state {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                Text(message)
                    .font(.system(size: 10))
                    .lineLimit(2)
                Spacer()
                Button {
                    voiceIn.clearFailure()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }

    private var canSend: Bool {
        !service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !service.isWorking
    }

    /// What the placeholder says depends on whether files are waiting, because "ask anything" is
    /// the wrong prompt when what is needed is an instruction about something specific.
    private var placeholder: String {
        service.attachments.isEmpty
            ? String(localized: "Ask anything about this Mac", comment: "Agent input placeholder")
            : String(localized: "What should I do with these?", comment: "Agent input placeholder with files waiting")
    }

    private func sendDraft() {
        guard canSend else { return }
        service.send(service.draft)
        service.draft = ""
    }
}

// MARK: - Pieces

/// A small round button in the panel's header.
private struct HeaderIcon: View {
    let symbol: String
    let isActive: Bool
    let help: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background {
                    Circle().fill(.primary.opacity(isHovered ? 0.12 : 0))
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The assistant's answer, drawn as the blocks it is made of.
///
/// The copy button appears on hover rather than sitting there permanently: it is wanted often and
/// looked at never, and a control on every message in a four-hundred-point panel is a column of
/// clutter down the side of the conversation.
private struct AssistantMessage: View {
    let text: String
    let isSpeaking: Bool
    var onSpeak: () -> Void

    @State private var isHovered = false
    @State private var hasCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(ChatMarkdown.blocks(of: text)) { block in
                switch block {
                case .prose(let prose):
                    Text(ChatMarkdown.attributed(prose))
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let code, let language):
                    ChatCodeBlock(code: code, language: language)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(0.08))
        }
        .overlay(alignment: .topTrailing) {
            // Shown while speaking even without the pointer, because something making noise has to
            // have a visible way to be stopped.
            if isHovered || isSpeaking {
                HStack(spacing: 3) {
                    MessageAction(
                        symbol: isSpeaking ? "stop.fill" : "speaker.wave.2",
                        tint: isSpeaking ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary),
                        help: isSpeaking
                            ? String(localized: "Stop reading", comment: "Chat")
                            : String(localized: "Read the answer aloud", comment: "Chat"),
                        action: onSpeak
                    )
                    MessageAction(
                        symbol: hasCopied ? "checkmark" : "doc.on.doc",
                        tint: hasCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary),
                        help: String(localized: "Copy the answer", comment: "Chat")
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        hasCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            hasCopied = false
                        }
                    }
                }
                .padding(4)
            }
        }
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
    }
}

/// One tool that ran, and — on request — exactly what it was given and what it gave back.
///
/// The disclosure is the point. This agent does things on somebody's machine, and "what did it
/// actually pass to that tool" should be answerable by the person whose machine it is rather than
/// only by reading the source.
private struct StepCard: View {
    let step: AgentEntry.Step

    @State private var isExpanded = false
    @State private var isHovered = false

    private var canExpand: Bool { !step.arguments.isEmpty || !step.output.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if !step.detail.isEmpty, !isExpanded {
                        Text(step.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                if canExpand, isHovered || isExpanded {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    if !step.arguments.isEmpty {
                        detail(String(localized: "Sent", comment: "Chat: a tool's arguments"), step.arguments)
                    }
                    if !step.output.isEmpty {
                        detail(String(localized: "Returned", comment: "Chat: a tool's result"), step.output)
                    }
                }
                .padding(.leading, 17)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture { if canExpand { isExpanded.toggle() } }
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isExpanded)
        .accessibilityHint(canExpand
            ? String(localized: "Shows what this tool was sent and what it returned", comment: "Chat")
            : "")
    }

    private func detail(_ label: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            // Bounded: a tool can return a whole file, and the card is not where that is read.
            Text(body.count > 1200 ? String(body.prefix(1200)) + "…" : body)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.black.opacity(0.22))
        }
    }
}

/// One of the little round actions that appear on a message.
private struct MessageAction: View {
    let symbol: String
    let tint: AnyShapeStyle
    let help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.35), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The microphone in the input row.
///
/// While it is listening it pulses, and the tooltip says whether the words are being recognised on
/// this Mac or sent to Apple — the one fact somebody dictating a private note would want, and the
/// one nobody thinks to look up.
private struct DictationButton: View {
    let voice: VoiceInput
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private var help: String {
        guard voice.isListening else {
            return String(localized: "Dictate", comment: "Chat: start speaking a message")
        }
        return voice.isOnDevice
            ? String(localized: "Listening — recognised on this Mac", comment: "Chat: dictation is on-device")
            : String(localized: "Listening — recognised by Apple's service", comment: "Chat: dictation is not on-device")
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: voice.isListening ? "waveform" : "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(voice.isListening ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(.red.opacity(voice.isListening ? 0.16 : 0))
                }
                .scaleEffect(voice.isListening && isPulsing && !reduceMotion ? 1.12 : 1)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .animation(
            voice.isListening && !reduceMotion
                ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                : .default,
            value: isPulsing
        )
        .onAppear { isPulsing = true }
    }
}
