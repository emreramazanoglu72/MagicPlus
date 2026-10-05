//
//  DownloadSettingsView.swift
//  tabmenu
//

import AppKit
import SwiftUI

struct DownloadSettingsView: View {
    let environment: AppEnvironment

    @Bindable private var preferences: Preferences

    init(environment: AppEnvironment) {
        self.environment = environment
        self.preferences = environment.preferences
    }

    private var store: DownloadStore { environment.downloads.store }
    private var bridge: BrowserBridge { environment.downloads.bridge }

    /// Re-read whenever the pane appears or an install is kicked off, so the state stops being
    /// wrong the moment the user acts on it.
    @State private var helper: URL?

    var body: some View {
        Form {
            Section {
                Toggle("Manage downloads", isOn: $preferences.isDownloadManagerEnabled)
                    .onChange(of: preferences.isDownloadManagerEnabled) { _, _ in
                        environment.downloads.updateMonitoring()
                    }

                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Text(store.downloadFolder.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                            .controlSize(.small)
                        if !preferences.downloadFolderPath.isEmpty {
                            Button("Reset") { preferences.downloadFolderPath = "" }
                                .controlSize(.small)
                        }
                    }
                }

                Toggle("Sort into folders by kind", isOn: $preferences.sortsDownloadsByKind)

                Stepper(
                    "Downloads at once: \(preferences.maximumConcurrentDownloads)",
                    value: $preferences.maximumConcurrentDownloads,
                    in: 1...6
                )
            }

            Section("Noticing links") {
                Toggle("Offer to download links you copy", isOn: $preferences.grabsLinksFromClipboard)
                    .onChange(of: preferences.grabsLinksFromClipboard) { _, _ in
                        environment.downloads.updateMonitoring()
                    }

                Toggle("Watch the front browser tab", isOn: $preferences.watchesBrowserTabs)
                    .onChange(of: preferences.watchesBrowserTabs) { _, _ in
                        environment.downloads.updateMonitoring()
                    }

                if let browser = environment.downloads.automationDeniedBrowser {
                    LabeledContent {
                        Button("Open Automation Settings") { openAutomationSettings() }
                            .controlSize(.small)
                    } label: {
                        Label(
                            "macOS refused access to \(browser.scriptName)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }

                    Text("Allow MagicPlus under Privacy & Security → Automation, then switch the setting off and on again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("A link you copy is offered in the island, and clicking the capsule opens the prompt — nothing is ever downloaded without that. Watching the browser reads only the address of the tab in front, which is the one thing macOS lets an app ask a browser; it needs Automation permission the first time, and it notices media pages and file links only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Media pages") {
                LabeledContent("Helper") {
                    HStack(spacing: 8) {
                        if let helper {
                            Label(helper.lastPathComponent, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .help(helper.path)
                        } else {
                            Label("Not installed", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.orange)
                            Button("Install…") {
                                MediaTool.runInstaller()
                                refreshHelper()
                            }
                            .controlSize(.small)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(MediaTool.installCommand, forType: .string)
                            }
                            .controlSize(.small)
                            .help(MediaTool.installCommand)
                        }
                        Button {
                            refreshHelper()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help("Look again")
                    }
                }

                TextField("Helper path", text: $preferences.mediaToolPath, prompt: Text("Found automatically"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: preferences.mediaToolPath) { _, _ in refreshHelper() }

                Picker("Default quality", selection: $preferences.preferredMediaQuality) {
                    ForEach(MediaQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }

                Picker("Use cookies from", selection: $preferences.mediaCookieSource) {
                    ForEach(MediaCookieSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }

                Text("YouTube increasingly refuses the stream it just handed out unless the request carries a session: a few megabytes arrive and then everything comes back 403. Pointing the helper at a browser you are signed into is the documented way through that, and it is also what gets an age-restricted page to play. It hands your session to `yt-dlp`, which is why it is off until you choose it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Video in a browser tab is not something a menu bar app can fetch on its own: the stream is behind the page, and MagicPlus ships no site extractors. What it can do is hand the page to `yt-dlp` if you have installed it, show the progress in the island, and keep it in the same queue as everything else. Install it with `brew install yt-dlp ffmpeg` — `ffmpeg` is what joins video and audio for the highest qualities.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Browser extension") {
                LabeledContent("Bridge") {
                    HStack(spacing: 8) {
                        if let port = bridge.port {
                            Label("Listening on \(String(port))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if preferences.isBrowserBridgeEnabled {
                            Label("Could not open a port", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Label("Off", systemImage: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle("Accept downloads from the browser extension", isOn: $preferences.isBrowserBridgeEnabled)
                    .onChange(of: preferences.isBrowserBridgeEnabled) { _, _ in
                        environment.downloads.updateMonitoring()
                    }

                if bridge.clients.isEmpty {
                    LabeledContent {
                        Button("Get the extension…") { openExtensionInstructions() }
                            .controlSize(.small)
                    } label: {
                        Text("No browser connected")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(bridge.clients) { client in
                        LabeledContent {
                            Button("Disconnect") { bridge.revoke(client) }
                                .controlSize(.small)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(client.name)
                                Text(client.pairedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Text("A browser cannot be asked what it is downloading — no API exposes that — so the extension comes to MagicPlus instead, over a port bound to this machine alone. It hands over the cookies and referer the site expects, which is what keeps a signed link working outside the browser. Nothing reaches the queue until you have approved a dialog naming the extension, and disconnecting revokes its token at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Queue") {
                LabeledContent("In the list") {
                    Text("\(store.items.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Button("Download link on the clipboard") {
                        environment.downloads.promptForClipboardLink()
                    }
                    Spacer()
                    Button("Clear finished") { store.clearFinished() }
                        .disabled(!store.items.contains(where: \.state.isFinished))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshHelper)
    }

    private func refreshHelper() {
        helper = MediaTool.resolve(configuredPath: preferences.mediaToolPath)
    }

    private func openExtensionInstructions() {
        guard let url = URL(
            string: "https://github.com/emreramazanoglu72/MagicPlus/tree/main/Extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func chooseFolder() {
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.canCreateDirectories = true
        dialog.allowsMultipleSelection = false
        dialog.directoryURL = store.downloadFolder
        dialog.prompt = String(localized: "Choose", comment: "Folder picker confirm button")

        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        preferences.downloadFolderPath = url.path
    }
}
