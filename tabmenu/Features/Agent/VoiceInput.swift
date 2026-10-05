//
//  VoiceInput.swift
//  MagicPlus
//

import AVFoundation
import Observation
import Speech
import os

/// Dictation for the chat's field.
///
/// What it deliberately does *not* do is send. Recognition mis-hears things, and this assistant acts
/// on the machine — deleting a file because "sil" was heard where "seç" was said is not a mistake
/// anybody should be able to make by speaking. The words land in the field, and the person still
/// presses send.
///
/// On-device recognition is asked for whenever the system can do it. That is the difference between
/// speech staying on this Mac and speech going to Apple's servers, and it is worth saying plainly in
/// Settings rather than leaving somebody to assume the friendlier answer.
@MainActor
@Observable
final class VoiceInput {
    enum State: Equatable {
        case idle
        case listening
        /// Something stopped it: no permission, no recogniser for this language, no microphone.
        case failed(String)
    }

    private(set) var state: State = .idle
    /// What has been heard so far, replaced as the recogniser changes its mind about earlier words.
    private(set) var transcript = ""
    /// Whether the words are being recognised on this Mac rather than sent away.
    private(set) var isOnDevice = false

    private let logger = Logger(subsystem: "com.tabmenu", category: "Voice")
    private let engine = AVAudioEngine()
    private var recogniser: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isListening: Bool { state == .listening }

    /// Whether dictation can be offered at all: a recogniser has to exist for the language, and
    /// offering a button that can only ever fail is worse than not offering one.
    static func isAvailable(locale: Locale = .current) -> Bool {
        SFSpeechRecognizer(locale: bestLocale(for: locale)) != nil
    }

    /// The locale to recognise in.
    ///
    /// The app's own language rather than the system's: somebody running MagicPlus in Turkish is
    /// telling it which language they are going to speak. Falls back to English, which every
    /// installation has.
    nonisolated static func bestLocale(for locale: Locale = .current) -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        if supported.contains(locale.identifier) { return locale }

        // Same language, any region: `tr` where the system says `tr-TR`, and the other way round.
        if let language = locale.language.languageCode?.identifier,
           let match = supported.first(where: { $0.hasPrefix(language) }) {
            return Locale(identifier: match)
        }
        return Locale(identifier: "en-US")
    }

    // MARK: - Listening

    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard !isListening else { return }
        transcript = ""

        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard authorization == .authorized else {
                    state = .failed(String(
                        localized: "Speech recognition is not allowed. Turn it on in System Settings → Privacy & Security.",
                        comment: "Voice input error"
                    ))
                    return
                }
                beginListening()
            }
        }
    }

    private func beginListening() {
        let locale = Self.bestLocale()
        guard let recogniser = SFSpeechRecognizer(locale: locale), recogniser.isAvailable else {
            state = .failed(String(
                localized: "No speech recogniser is available for this language.",
                comment: "Voice input error"
            ))
            return
        }
        self.recogniser = recogniser

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Kept on this Mac when the system can. Not every language has an on-device model, so this
        // is a preference rather than a guarantee — and the interface says which one is happening.
        if recogniser.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            isOnDevice = true
        } else {
            isOnDevice = false
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            state = .failed(String(localized: "No microphone is available.", comment: "Voice input error"))
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanUp()
            state = .failed(error.localizedDescription)
            return
        }

        state = .listening
        task = recogniser.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    transcript = result.bestTranscription.formattedString
                    if result.isFinal { stop() }
                }
                if error != nil, isListening { stop() }
            }
        }
    }

    func stop() {
        guard state == .listening else {
            cleanUp()
            return
        }
        cleanUp()
        state = .idle
    }

    private func cleanUp() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Clears a failure so the button can be tried again.
    func clearFailure() {
        if case .failed = state { state = .idle }
    }
}
