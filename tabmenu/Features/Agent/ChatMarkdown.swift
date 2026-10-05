//
//  ChatMarkdown.swift
//  MagicPlus
//

import SwiftUI

/// Splits an answer into the pieces the chat draws differently.
///
/// SwiftUI's `Text` understands *inline* markdown — bold, code spans, links — and nothing about
/// block structure, so a fenced code block arrived as a paragraph with three backticks in it. That
/// matters more here than it sounds: an assistant is asked for commands more than for anything else,
/// and a command that cannot be read or copied is an answer that was not given.
///
/// Fences only. Tables, nested lists and the rest of CommonMark are a rabbit hole with a small
/// return in a four-hundred-point panel — prose and code is what these answers are made of.
nonisolated enum ChatMarkdown {
    enum Block: Equatable, Identifiable {
        case prose(String)
        /// Code, with the language the fence named, if it named one.
        case code(String, language: String?)

        var id: String {
            switch self {
            case .prose(let text): "p:\(text.hashValue)"
            case .code(let text, let language): "c:\(language ?? "")\(text.hashValue)"
            }
        }
    }

    /// The answer as blocks, in order.
    ///
    /// An unterminated fence — which happens whenever an answer is cut off — closes at the end
    /// rather than swallowing the rest as prose, because half a code block is still code.
    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.prose(joined)) }
            prose.removeAll()
        }

        func flushCode() {
            let joined = code.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.code(joined, language: language))
            }
            code.removeAll()
            language = nil
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    let fence = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                    let named = fence.trimmingCharacters(in: .whitespaces)
                    language = named.isEmpty ? nil : named
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }

        if inCode { flushCode() } else { flushProse() }
        return blocks
    }

    /// Prose as an attributed string, with the inline markdown honoured and the line breaks kept.
    ///
    /// `.inlineOnlyPreservingWhitespace` rather than the default: the default collapses newlines,
    /// which turns a list into one long sentence.
    @MainActor
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// One code block: monospaced, scrollable sideways, and copyable in one press.
struct ChatCodeBlock: View {
    let code: String
    let language: String?

    @State private var hasCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    hasCopied = true
                    // Says it worked, then stops saying it. A tick that never goes away stops
                    // meaning "just now".
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        hasCopied = false
                    }
                } label: {
                    Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(hasCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Copy", comment: "Chat: copy a code block"))
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 2)

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 7)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.28))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}
