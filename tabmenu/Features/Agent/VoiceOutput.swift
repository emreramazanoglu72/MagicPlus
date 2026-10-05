//
//  VoiceOutput.swift
//  MagicPlus
//

import AVFoundation
import NaturalLanguage
import Observation

/// Reads an answer out loud.
///
/// Entirely on this Mac and without any permission at all — `AVSpeechSynthesizer` is offline, which
/// makes this the cheap half of talking to the assistant. The expensive half is listening, and it is
/// the half that needs asking.
///
/// The voice follows the *answer's* language rather than the app's. The assistant is told to answer
/// in whatever language it was asked in, so a Turkish question gets a Turkish answer, and reading
/// Turkish with an English voice is worse than not reading it.
@MainActor
@Observable
final class VoiceOutput {
    private(set) var speakingEntryID: UUID?

    private let synthesiser = AVSpeechSynthesizer()

    var isSpeaking: Bool { speakingEntryID != nil }

    func toggle(_ text: String, id: UUID) {
        if speakingEntryID == id {
            stop()
        } else {
            speak(text, id: id)
        }
    }

    func speak(_ text: String, id: UUID) {
        stop()
        let spoken = Self.spoken(from: text)
        guard !spoken.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: spoken)
        if let code = Self.languageCode(of: spoken) {
            utterance.voice = AVSpeechSynthesisVoice(language: code)
        }
        synthesiser.speak(utterance)
        speakingEntryID = id

        // `AVSpeechSynthesizer` reports finishing through a delegate; polling its own flag is
        // simpler than an object whose only job is to set a bool, and this is once a second.
        Task { [weak self] in
            while let self, synthesiser.isSpeaking {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard let self, speakingEntryID == id else { return }
            speakingEntryID = nil
        }
    }

    func stop() {
        synthesiser.stopSpeaking(at: .immediate)
        speakingEntryID = nil
    }

    // MARK: - What to say

    /// The answer with the parts nobody wants read aloud taken out.
    ///
    /// Code blocks especially: a shell command read character by character is noise, and it is the
    /// one thing in these answers most likely to be there. What is left is a sentence saying there
    /// was code, which is the useful part when listening rather than looking.
    nonisolated static func spoken(from text: String) -> String {
        var pieces: [String] = []
        var codeBlocks = 0

        for block in ChatMarkdown.blocks(of: text) {
            switch block {
            case .prose(let prose):
                pieces.append(stripped(prose))
            case .code:
                codeBlocks += 1
            }
        }

        if codeBlocks > 0 {
            pieces.append(String(
                localized: "There is code in this answer — read it on screen.",
                comment: "Spoken instead of reading a code block aloud"
            ))
        }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inline markdown read as its words rather than its punctuation.
    private nonisolated static func stripped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "- ", with: "")
    }

    /// The language the text is in, for choosing a voice. `nil` when it cannot tell, which leaves
    /// the system's default voice — the right fallback, because a wrong guess sounds worse than no
    /// guess.
    nonisolated static func languageCode(of text: String) -> String? {
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(text)
        guard let language = recogniser.dominantLanguage else { return nil }
        // Below this the guess is coin-flipping, and a Turkish answer read in English is worse than
        // an English voice reading nothing.
        guard let confidence = recogniser.languageHypotheses(withMaximum: 1)[language],
              confidence > 0.5
        else { return nil }
        return language.rawValue
    }
}
