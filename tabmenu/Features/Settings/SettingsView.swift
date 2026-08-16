//
//  SettingsView.swift
//  tabmenu
//

import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            GeneralSettingsView(environment: environment)
                .tabItem { Label("General", systemImage: "gearshape") }

            PreviewSettingsView(environment: environment)
                .tabItem { Label("Previews", systemImage: "macwindow.on.rectangle") }

            ShortcutSettingsView(environment: environment)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            ClipboardSettingsView(preferences: environment.preferences, service: environment.clipboard)
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
        }
        // Fixed size: the window is not resizable, so the tabs must not ask it to grow when
        // switching between panes of different heights.
        .frame(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)
    }

    static let windowSize = CGSize(width: 520, height: 580)
}

private struct GeneralSettingsView: View {
    let environment: AppEnvironment

    @Bindable private var preferences: Preferences

    init(environment: AppEnvironment) {
        self.environment = environment
        self.preferences = environment.preferences
    }

    @State private var selectedLanguage = AppLanguage.current
    @State private var launchLanguage = AppLanguage.current

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                Picker("Menu bar shows", selection: $preferences.menuBarMetric) {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .onChange(of: preferences.menuBarMetric) { _, _ in
                    environment.updateMonitorMode(isPopoverOpen: false)
                }

                Picker("Language", selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .onChange(of: selectedLanguage) { _, language in
                    AppLanguage.apply(language)
                }

                if selectedLanguage != launchLanguage {
                    LabeledContent {
                        Button("Relaunch Now") { AppLanguage.relaunch() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } label: {
                        Text("Takes effect after relaunch")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Windows") {
                LabeledContent("Gap between windows") {
                    HStack {
                        Slider(value: $preferences.windowGap, in: 0...24, step: 2)
                        Text("\(Int(preferences.windowGap))pt")
                            .font(.callout.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Toggle("Snap when dragged to a screen edge", isOn: $preferences.isDragSnapEnabled)
                    .onChange(of: preferences.isDragSnapEnabled) { _, _ in
                        environment.dragSnap.updateMonitoring()
                    }
            }

            WindowRulesSection(store: environment.windowRules)

            Section("Keep awake") {
                Toggle("Keep the Mac awake", isOn: environment.keepAwake.binding)

                Picker("Duration", selection: environment.keepAwake.durationBinding) {
                    ForEach(KeepAwakeDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }

                Toggle("Also keep the display on", isOn: $preferences.keepsDisplayAwake)
                    .onChange(of: preferences.keepsDisplayAwake) { _, _ in
                        environment.keepAwake.reapplyOptions()
                    }

                Toggle("Resume when MagicPlus launches", isOn: $preferences.resumesKeepAwakeAtLaunch)

                Text("Holds off display sleep, system sleep, disk spin-down and the idle lock screen — the same set of assertions as `caffeinate -dims`. Turning the display option off lets the screen sleep, which also locks the Mac. Closing the lid still sleeps the Mac — no app can prevent that — and quitting MagicPlus releases the hold, so keep \"Resume when tabmenu launches\" on if the session must survive restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        Label(
                            environment.permission.isTrusted ? "Granted" : "Not granted",
                            systemImage: environment.permission.isTrusted ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(environment.permission.isTrusted ? .green : .orange)

                        if !environment.permission.isTrusted {
                            Button("Grant…") { environment.permission.request() }
                        }
                    }
                }
                Text("Required to move windows and to paste automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Review All Permissions…") {
                    environment.onboarding.show()
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Place an app automatically whenever it opens.
private struct WindowRulesSection: View {
    let store: WindowRuleStore

    @State private var isAdding = false
    @State private var chosenApplication: String = ""
    @State private var chosenZone: WindowZone = .leftHalf

    /// Regular apps that are running now and do not already have a rule.
    private var candidates: [NSRunningApplication] {
        let claimed = Set(store.rules.map(\.bundleIdentifier))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier.map { !claimed.contains($0) } ?? false }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Section("Rules") {
            Text("When one of these apps opens, its first window is placed for you.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(store.rules) { rule in
                LabeledContent(rule.applicationName) {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
                            get: { rule.zone },
                            set: { store.update(rule, zone: $0) }
                        )) {
                            ForEach(WindowZone.allCases) { zone in
                                Text(zone.title).tag(zone)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)

                        Button {
                            store.remove(rule)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove rule for \(rule.applicationName)")
                    }
                }
            }

            if isAdding {
                HStack(spacing: 8) {
                    Picker("", selection: $chosenApplication) {
                        Text("Choose an app").tag("")
                        ForEach(candidates, id: \.processIdentifier) { application in
                            Text(application.localizedName ?? "?")
                                .tag(application.bundleIdentifier ?? "")
                        }
                    }
                    .labelsHidden()

                    Picker("", selection: $chosenZone) {
                        ForEach(WindowZone.allCases) { zone in
                            Text(zone.title).tag(zone)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)

                    Button("Add", action: commit)
                        .disabled(chosenApplication.isEmpty)
                    Button("Cancel") { isAdding = false }
                }
            } else {
                Button("Add Rule…") { isAdding = true }
            }
        }
    }

    private func commit() {
        guard let application = candidates.first(where: { $0.bundleIdentifier == chosenApplication }),
              let bundleIdentifier = application.bundleIdentifier
        else { return }
        store.add(
            bundleIdentifier: bundleIdentifier,
            applicationName: application.localizedName ?? bundleIdentifier,
            zone: chosenZone
        )
        chosenApplication = ""
        isAdding = false
    }
}

private struct PreviewSettingsView: View {
    let environment: AppEnvironment

    @Bindable private var preferences: Preferences

    init(environment: AppEnvironment) {
        self.environment = environment
        self.preferences = environment.preferences
    }

    var body: some View {
        Form {
            Section("Dock previews") {
                Toggle("Show window previews on Dock hover", isOn: $preferences.isDockPreviewEnabled)
                    .onChange(of: preferences.isDockPreviewEnabled) { _, _ in
                        environment.dockPreview.updateMonitoring()
                    }

                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $preferences.dockHoverDelay, in: 0...1, step: 0.05)
                        Text("\(preferences.dockHoverDelay, specifier: "%.2f")s")
                            .font(.callout.monospacedDigit())
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                .disabled(!preferences.isDockPreviewEnabled)
            }

            Section("Notch") {
                Toggle("Show the notch panel", isOn: $preferences.isNotchPanelEnabled)
                    .onChange(of: preferences.isNotchPanelEnabled) { _, _ in
                        environment.notchPanel.updateMonitoring()
                    }
                Text("Hover the notch for the file shelf and playback controls. Displays without a notch use a strip in the middle of the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window switcher") {
                Picker("Layout", selection: $preferences.switcherLayout) {
                    ForEach(SwitcherLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbolName).tag(layout)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Thumbnails") {
                Toggle("Capture live window images", isOn: $preferences.showsWindowThumbnails)
                    .onChange(of: preferences.showsWindowThumbnails) { _, isOn in
                        if isOn {
                            environment.screenRecordingPermission.request()
                        } else {
                            environment.thumbnails.clear()
                        }
                    }

                LabeledContent("Screen Recording") {
                    HStack(spacing: 8) {
                        Label(
                            environment.screenRecordingPermission.isGranted ? "Granted" : "Not granted",
                            systemImage: environment.screenRecordingPermission.isGranted
                                ? "checkmark.circle.fill"
                                : "xmark.circle.fill"
                        )
                        .foregroundStyle(environment.screenRecordingPermission.isGranted ? .green : .orange)

                        if !environment.screenRecordingPermission.isGranted {
                            Button("Open Settings") {
                                environment.screenRecordingPermission.openSystemSettings()
                            }
                        }
                    }
                }

                Text("Without this permission previews fall back to application icons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettingsView: View {
    let environment: AppEnvironment

    var body: some View {
        Form {
            Section("Windows") {
                ForEach(WindowAction.allCases) { action in
                    shortcutRow(for: .window(action))
                }
            }
            Section("App") {
                shortcutRow(for: .showClipboard)
                shortcutRow(for: .switchWindows)
                shortcutRow(for: .togglePanel)
                shortcutRow(for: .toggleKeepAwake)
            }
            Section {
                Button("Restore Defaults") {
                    environment.preferences.resetShortcutsToDefaults()
                    environment.registerShortcuts()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(for action: HotKeyAction) -> some View {
        LabeledContent(action.title) {
            ShortcutRecorderField(
                action: action,
                combo: Binding(
                    get: { environment.preferences.shortcut(for: action) },
                    set: { environment.preferences.setShortcut($0, for: action) }
                ),
                onChange: { _ in environment.registerShortcuts() }
            )
        }
    }
}

private struct ClipboardSettingsView: View {
    @Bindable var preferences: Preferences
    let service: ClipboardService

    @State private var newBundleID = ""

    var body: some View {
        Form {
            Section {
                Toggle("Record clipboard history", isOn: $preferences.isClipboardEnabled)
                Toggle("Paste automatically after selecting", isOn: $preferences.pastesAutomatically)
                Toggle("Skip card numbers, keys and tokens", isOn: $preferences.skipsSensitiveContent)
                Picker("History limit", selection: $preferences.historyLimit) {
                    ForEach([50, 100, 200, 500, 1000], id: \.self) { limit in
                        Text("\(limit) items").tag(limit)
                    }
                }
            }

            Section("Ignored apps") {
                Text("Clipboard contents from these bundle identifiers are never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(preferences.ignoredBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                            .font(.callout.monospaced())
                        Spacer()
                        Button {
                            preferences.ignoredBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(bundleID)")
                    }
                }

                HStack {
                    TextField("com.example.app", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addBundleID)
                    Button("Add", action: addBundleID)
                        .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                Button("Clear History", role: .destructive) {
                    service.clearHistory(includingPinned: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addBundleID() {
        let value = newBundleID.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !preferences.ignoredBundleIDs.contains(value) else { return }
        preferences.ignoredBundleIDs.append(value)
        newBundleID = ""
    }
}
