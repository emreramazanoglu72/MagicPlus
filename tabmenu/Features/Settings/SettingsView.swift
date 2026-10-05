//
//  SettingsView.swift
//  tabmenu
//

import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment

    /// Settings for a module that is switched off would be settings for something that is not
    /// running — and a row of tabs is where an app most visibly claims to do more than it does.
    private func on(_ module: AppModule) -> Bool { environment.preferences.isEnabled(module) }

    var body: some View {
        TabView {
            GeneralSettingsView(environment: environment)
                .tabItem { Label("General", systemImage: "gearshape") }

            ModuleSettingsView(environment: environment)
                .tabItem { Label("Modules", systemImage: "square.grid.2x2") }

            if on(.dock) {
                DockSettingsView(environment: environment)
                    .tabItem { Label("Dock", systemImage: "dock.rectangle") }
            }

            if on(.dockPreviews) || on(.notch) || on(.windowSwitcher) {
                PreviewSettingsView(environment: environment)
                    .tabItem { Label("Previews", systemImage: "macwindow.on.rectangle") }
            }

            if on(.menuBar) {
                MenuBarSettingsView(environment: environment)
                    .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            }

            if on(.hardware) {
                HardwareSettingsView(environment: environment)
                    .tabItem { Label("Battery", systemImage: "battery.100percent") }
            }

            ShortcutSettingsView(environment: environment)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            Form { AISettingsView(environment: environment) }
                .formStyle(.grouped)
                .tabItem { Label("AI", systemImage: "sparkles") }

            if on(.clipboard) {
                ClipboardSettingsView(preferences: environment.preferences, service: environment.clipboard)
                    .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            }

            if on(.downloads) {
                DownloadSettingsView(environment: environment)
                    .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            }
        }
        // Fixed size: the window is not resizable, so the tabs must not ask it to grow when
        // switching between panes of different heights.
        .frame(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)
    }

    static let windowSize = CGSize(width: 560, height: 600)
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

            if environment.preferences.isEnabled(.windows) {
                windowSection
                WindowRulesSection(store: environment.windowRules)
            }

            if environment.preferences.isEnabled(.keepAwake) {
                keepAwakeSection
            }

            permissionsSection

            Section("Help") {
                Button("Report an Issue…") {
                    IssueReport.compose(
                        preferences: preferences,
                        accessibility: environment.permission,
                        screenRecording: environment.screenRecordingPermission
                    )
                }
                Text("Opens an email with the build, this Mac, which modules are on and any errors this session recorded — nothing is sent until you press send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var windowSection: some View {
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
    }

    private var keepAwakeSection: some View {
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

            Text("Holds off display sleep, system sleep, disk spin-down and the idle lock screen — the same set of assertions as `caffeinate -dims`. Turning the display option off lets the screen sleep, which also locks the Mac. Closing the lid still sleeps the Mac — no app can prevent that — and quitting MagicPlus releases the hold, so keep \"Resume when MagicPlus launches\" on if the session must survive restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Nothing to grant is a real state here: with every module that needs a permission switched
    /// off, a pane inviting the user to hand over Accessibility would be asking for nothing.
    @ViewBuilder
    private var permissionsSection: some View {
        let needed = AppModule.permissionsNeeded(where: preferences.isEnabled)

        if !needed.isEmpty {
            Section("Permissions") {
                if needed.contains(.accessibility) {
                    LabeledContent("Accessibility") {
                        HStack(spacing: 8) {
                            Label(
                                environment.permission.isTrusted ? "Granted" : "Not granted",
                                systemImage: environment.permission.isTrusted
                                    ? "checkmark.circle.fill"
                                    : "xmark.circle.fill"
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
                }

                Button("Review All Permissions…") {
                    environment.onboarding.show()
                }
            }
        }
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
                        Picker("Zone", selection: Binding(
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
                    Picker("App", selection: $chosenApplication) {
                        Text("Choose an app").tag("")
                        ForEach(candidates, id: \.processIdentifier) { application in
                            Text(application.localizedName ?? "?")
                                .tag(application.bundleIdentifier ?? "")
                        }
                    }
                    .labelsHidden()

                    Picker("Zone", selection: $chosenZone) {
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

/// Everything about the Dock in one place, which is where someone looking for it will look.
private struct DockSettingsView: View {
    let environment: AppEnvironment

    @Bindable private var preferences: Preferences

    init(environment: AppEnvironment) {
        self.environment = environment
        self.preferences = environment.preferences
    }

    var body: some View {
        Form {
            Section("Custom dock") {
                Toggle("Draw MagicPlus's own dock", isOn: $preferences.isCustomDockEnabled)
                    .onChange(of: preferences.isCustomDockEnabled) { _, _ in
                        environment.customDock.updateState()
                    }
                Text("macOS exposes nothing about the real Dock's appearance, so the only way to change how a dock looks is to draw one. Yours opens with the icons already arranged the way they are now — they are read from the Dock's own list and never rewritten. While this is on, the system Dock is hidden; switching it off gives it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if preferences.isCustomDockEnabled {
                DockStyleSections(preferences: preferences, controller: environment.customDock)
            }

            DockTweakSections(service: environment.dockTweaks)
        }
        .formStyle(.grouped)
    }
}

/// The look of the app's own dock.
private struct DockStyleSections: View {
    @Bindable var preferences: Preferences
    let controller: DockReplacementController

    /// Every change is written to one value and then handed to the window, so a slider drag is a
    /// live preview rather than a guess followed by a restart.
    private func apply(_ change: (inout DockStyle) -> Void) {
        var style = preferences.dockStyle
        change(&style)
        preferences.dockStyle = style
        controller.styleChanged()
    }

    var body: some View {
        Section {
            Button("Restore the Default Look") {
                preferences.dockStyle = DockStyle()
                controller.styleChanged()
            }
            Text("Everything below, back to how the bar ships.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Appearance") {
            Picker("Surface", selection: Binding(
                get: { preferences.dockStyle.surface },
                set: { value in apply { $0.surface = value } }
            )) {
                ForEach(DockStyle.Surface.allCases) { surface in
                    Text(surface.title).tag(surface)
                }
            }

            if preferences.dockStyle.surface != .none {
                ColorPicker("Tint", selection: Binding(
                    get: { preferences.dockStyle.tint ?? .black },
                    set: { value in apply { $0.tintHex = value.hexString } }
                ))

                slider("Opacity", value: Binding(
                    get: { preferences.dockStyle.backgroundOpacity },
                    set: { value in apply { $0.backgroundOpacity = value } }
                ), range: 0...1, format: "%.0f%%", scale: 100)

            }
        }

        Section("Size and position") {
            Picker("Edge", selection: Binding(
                get: { preferences.dockStyle.edge },
                set: { value in apply { $0.edge = value } }
            )) {
                ForEach(DockStyle.Edge.allCases) { edge in
                    Text(edge.title).tag(edge)
                }
            }

            slider("Icon size", value: Binding(
                get: { preferences.dockStyle.iconSize },
                set: { value in apply { $0.iconSize = value } }
            ), range: 24...96, format: "%.0fpt")

            slider("Spacing", value: Binding(
                get: { preferences.dockStyle.spacing },
                set: { value in apply { $0.spacing = value } }
            ), range: 0...24, format: "%.0fpt")

            slider("Distance from the edge", value: Binding(
                get: { preferences.dockStyle.edgeMargin },
                set: { value in apply { $0.edgeMargin = value } }
            ), range: 0...40, format: "%.0fpt")
        }

        Section("Shape") {
            Toggle("Span the whole edge", isOn: Binding(
                get: { preferences.dockStyle.fillsEdge },
                set: { value in apply { $0.fillsEdge = value } }
            ))

            if preferences.dockStyle.fillsEdge {
                Picker("Icons", selection: Binding(
                    get: { preferences.dockStyle.alignment },
                    set: { value in apply { $0.alignment = value } }
                )) {
                    ForEach(DockStyle.Alignment.allCases) { alignment in
                        Text(alignment.title).tag(alignment)
                    }
                }
            }

            Picker("Running mark", selection: Binding(
                get: { preferences.dockStyle.indicator },
                set: { value in apply { $0.indicator = value } }
            )) {
                ForEach(DockStyle.Indicator.allCases) { indicator in
                    Text(indicator.title).tag(indicator)
                }
            }

            Toggle("Grow the icon under the pointer", isOn: Binding(
                get: { preferences.dockStyle.highlightsHovered },
                set: { value in apply { $0.highlightsHovered = value } }
            ))

            Toggle("Hide it until the pointer reaches the edge", isOn: Binding(
                get: { preferences.dockStyle.autoHides },
                set: { value in
                    apply { $0.autoHides = value }
                    controller.autoHideChanged()
                }
            ))

            if preferences.dockStyle.fillsEdge, !preferences.dockStyle.autoHides {
                Toggle("Keep windows out of its way", isOn: Binding(
                    get: { preferences.dockStyle.reservesSpace },
                    set: { value in apply { $0.reservesSpace = value } }
                ))
                Text("Only the Dock and the menu bar can shrink the space macOS gives to windows, so no app can make another app's window respect a strip down the side. What this does is stop MagicPlus putting windows there: tiling, drag-to-edge snapping and saved layouts all leave it alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Contents") {
            Toggle("Show running apps that are not pinned", isOn: Binding(
                get: { preferences.dockStyle.showsRunningApps },
                set: { value in
                    apply { $0.showsRunningApps = value }
                    controller.reloadTiles()
                }
            ))
            Text("The icons themselves come from the system Dock's list, so rearranging them there rearranges them here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        scale: Double = 1
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue * scale))
                    .font(.callout.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// The Dock settings Apple ships and never shows.
///
/// Each row reads the Dock's own preferences rather than a copy kept here, so a value someone
/// changed in Terminal shows up in this list, and off means "as macOS had it" rather than "our
/// other value".
private struct DockTweakSections: View {
    let service: DockTweakService

    var body: some View {
        Section("Dock") {
            ForEach(DockTweakService.Tweak.allCases) { tweak in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(tweak.title, isOn: Binding(
                        get: { service.isOn(tweak) },
                        set: { service.set(tweak, on: $0) }
                    ))
                    Text(tweak.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Minimise effect", selection: Binding(
                get: { service.minimizeEffect },
                set: { service.setMinimizeEffect($0) }
            )) {
                ForEach(DockTweakService.MinimizeEffect.allCases) { effect in
                    Text(effect.title).tag(effect)
                }
            }
            Text("System Settings offers two of the three the Dock can draw.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Separators") {
            LabeledContent("Blank tiles in the Dock") {
                HStack(spacing: 8) {
                    Text("\(service.separatorCount)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Add") { service.addSeparator() }
                    Button("Remove All") { service.removeSeparators() }
                        .disabled(service.separatorCount == 0)
                }
            }
            Text("A blank tile the Dock has always understood, to group icons apart. Your own icons are never rearranged — one is added at the end, or the blank ones are taken out again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Button("Restore macOS Defaults") { service.restoreDefaults() }
                .disabled(!service.hasChanges)
            Text("Removes only the settings on this page. The Dock restarts to pick them up, which takes a moment and loses nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutSettingsView: View {
    let environment: AppEnvironment

    /// Only shortcuts the app actually holds. A recorder for a switched-off module would record a
    /// key nothing is listening for.
    private func owned(_ action: HotKeyAction) -> Bool {
        environment.preferences.ownsShortcut(for: action)
    }

    var body: some View {
        Form {
            if owned(.window(.left)) {
                Section("Windows") {
                    ForEach(WindowAction.allCases) { action in
                        shortcutRow(for: .window(action))
                    }
                }
            }
            Section("App") {
                if owned(.showClipboard) { shortcutRow(for: .showClipboard) }
                if owned(.switchWindows) { shortcutRow(for: .switchWindows) }
                shortcutRow(for: .togglePanel)
                if owned(.toggleKeepAwake) { shortcutRow(for: .toggleKeepAwake) }
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
