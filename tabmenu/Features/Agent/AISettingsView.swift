//
//  AISettingsView.swift
//  MagicPlus
//

import SwiftUI

/// Where the assistant gets its model.
///
/// The key never reaches this view's storage: it is typed into a field, written to the keychain,
/// and read back only as "there is one" — which is why the field shows a placeholder rather than
/// the secret once it is saved. A settings pane that redisplays somebody's API key is a settings
/// pane that leaks it to whoever is behind them.
struct AISettingsView: View {
    let environment: AppEnvironment

    @Bindable private var preferences: Preferences

    @State private var key = ""
    @State private var hasStoredKey = false
    @State private var test: TestState = .idle

    /// What the provider says it will accept, when it has been asked and answered.
    @State private var models: [String] = []
    @State private var isLoadingModels = false
    @State private var modelsCameFromProvider = false
    /// Set when the stored model is not one of the offered ones, so the field appears rather than
    /// the picker silently disagreeing with what is saved.
    @State private var usesCustomModel = false

    /// The picker entry that means "let me type it".
    private static let customTag = "\u{1}custom"
    /// The entry that means "whatever this provider's default is", stored as an empty string.
    private static let defaultTag = ""

    private enum TestState: Equatable {
        case idle
        case running
        case passed(String)
        case failed(String)
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.preferences = environment.preferences
    }

    private var provider: AgentProvider {
        AgentProvider(rawValue: preferences.agentProvider) ?? .anthropic
    }

    var body: some View {
        Section {
            Toggle("Show the assistant in the dock", isOn: Binding(
                get: { preferences.isAgentEnabled },
                set: { value in
                    preferences.isAgentEnabled = value
                    environment.customDock.agentAvailabilityChanged()
                }
            ))
            Text("A button on the bar opens a chat that can search files, open applications, take notes and read this Mac's status.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Model") {
            Picker("Provider", selection: Binding(
                get: { provider },
                set: { value in
                    preferences.agentProvider = value.rawValue
                    // The model name belongs to the provider that was chosen; carrying one across
                    // would silently ask OpenAI for a Claude model.
                    preferences.agentModel = ""
                    usesCustomModel = false
                    loadKey()
                    test = .idle
                    refreshModels()
                }
            )) {
                ForEach(AgentProvider.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            if provider == .cloudflare {
                TextField("Account ID", text: $preferences.agentCloudflareAccount)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(refreshModels)
            }

            HStack {
                Picker("Model", selection: modelSelection) {
                    Text("Default (\(provider.defaultModel))").tag(Self.defaultTag)
                    if !offeredModels.isEmpty {
                        Divider()
                        ForEach(offeredModels, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Divider()
                    Text("Custom…").tag(Self.customTag)
                }

                if isLoadingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        refreshModels()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(String(localized: "Reload the model list", comment: "AI settings"))
                    .disabled(!hasStoredKey)
                }
            }

            if usesCustomModel {
                TextField("Model name", text: $preferences.agentModel, prompt: Text(provider.defaultModel))
                    .textFieldStyle(.roundedBorder)
            }

            if !modelsCameFromProvider {
                Text("Showing a built-in list. Set a key and reload to see the models your account can actually use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("API key") {
            HStack {
                SecureField(
                    "API key",
                    text: $key,
                    prompt: Text(hasStoredKey
                        ? String(localized: "Saved in your keychain", comment: "AI settings: a key is already stored")
                        : String(localized: "Paste your key", comment: "AI settings: no key yet"))
                )
                .textFieldStyle(.roundedBorder)

                Button("Save") {
                    guard KeychainStore.save(
                        key, service: KeychainStore.agentService, account: provider.rawValue
                    ) else {
                        test = .failed(String(
                            localized: "The keychain refused to store the key.",
                            comment: "AI settings: the keychain write failed"
                        ))
                        return
                    }
                    key = ""
                    hasStoredKey = true
                    test = .idle
                    refreshModels()
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)

                if hasStoredKey {
                    Button("Remove") {
                        KeychainStore.delete(service: KeychainStore.agentService, account: provider.rawValue)
                        hasStoredKey = false
                        test = .idle
                        models = []
                        modelsCameFromProvider = false
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Test the connection", action: runTest)
                    .disabled(!hasStoredKey || test == .running)
                testResult
            }

            Text("Keys are kept in your login keychain, one per provider — never in this app's settings file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("What gets sent") {
            Text("Your message, the conversation so far, and whatever a tool returns. Searching files sends their names and paths, never their contents. Two tools do send text: reading the system status sends those readings, and searching your clipboard history sends the matching entries — so treat that one as sending whatever you had copied.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Nothing is sent until you type something, and nothing goes anywhere but the provider chosen above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            loadKey()
            refreshModels()
        }
    }

    /// The provider's own list when it answered, the built-in one otherwise, with whatever is
    /// stored folded in — a saved model missing from the picker is a picker that lies about what
    /// is configured.
    private var offeredModels: [String] {
        let base = models.isEmpty ? ModelCatalog.fallback(for: provider) : models
        let stored = preferences.agentModel
        guard !stored.isEmpty, !base.contains(stored), !usesCustomModel else { return base }
        return [stored] + base
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                if usesCustomModel { return Self.customTag }
                return preferences.agentModel
            },
            set: { value in
                if value == Self.customTag {
                    usesCustomModel = true
                } else {
                    usesCustomModel = false
                    preferences.agentModel = value
                }
                test = .idle
            }
        )
    }

    private func refreshModels() {
        guard let apiKey = KeychainStore.read(
            service: KeychainStore.agentService,
            account: provider.rawValue
        ), !apiKey.isEmpty else {
            models = []
            modelsCameFromProvider = false
            return
        }

        isLoadingModels = true
        let chosen = provider
        let account = preferences.agentCloudflareAccount
        Task {
            let fetched = await ModelCatalog.fetch(provider: chosen, apiKey: apiKey, account: account)
            // The pane may have moved on to another provider while this was in flight.
            guard chosen == provider else { return }
            models = fetched
            modelsCameFromProvider = !fetched.isEmpty
            isLoadingModels = false
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .passed(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
    }

    private func loadKey() {
        hasStoredKey = KeychainStore.read(
            service: KeychainStore.agentService,
            account: provider.rawValue
        )?.isEmpty == false
        key = ""
    }

    /// One real round trip with no tools attached. A key that parses is not a key that works, and
    /// finding that out here beats finding it out mid-question.
    private func runTest() {
        test = .running
        Task {
            do {
                let model = try ProviderFactory.make(preferences: preferences)
                let reply = try await model.send(
                    system: "Reply with the single word: ready.",
                    turns: [.user("ping")],
                    tools: []
                )
                let answer = (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                test = .passed(answer.isEmpty
                    ? String(localized: "Connected", comment: "AI settings: connection test passed")
                    : String(answer.prefix(40)))
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}
