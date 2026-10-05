//
//  AppEnvironment.swift
//  tabmenu
//

import AppKit
import Observation

/// Composition root: owns the long-lived services and wires global shortcuts to them.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let preferences: Preferences
    let permission: AccessibilityPermission
    let screenRecordingPermission: ScreenRecordingPermission
    let permissionCatalog: PermissionCatalog
    let windowManager: WindowManagerService
    let layouts: WorkspaceLayoutStore
    let windowRules: WindowRuleStore
    let dragSnap: DragSnapController
    let clipboard: ClipboardService
    let monitor: SystemMonitorService
    let keepAwake: KeepAwakeService
    let thumbnails: WindowThumbnailService
    let calendar: CalendarService
    let shelf: ShelfStore
    let downloads: DownloadCoordinator
    let clipboardPanel: ClipboardPanelController
    let windowSwitcher: WindowSwitcherPanelController
    let dockPreview: DockPreviewController
    let dockTweaks = DockTweakService()
    let customDock: DockReplacementController
    let audioMixer: AudioMixerService
    let displayBrightness: DisplayBrightnessService
    let notchPanel: NotchWindowController
    let menuPalette: MenuPalettePanelController
    let menuBarManager: MenuBarManagerService
    let hiddenItemsBar: HiddenItemsBarController
    let menuBarSearch: MenuBarSearchPanelController
    let menuBarAppearance: MenuBarAppearanceOverlay
    let hardware: HardwareService
    let helperInstaller: HelperInstaller
    let chargeLimit: ChargeLimitService
    let quickNote: QuickNotePanelController
    let presentation: PresentationModeService
    let onboarding: OnboardingWindowController
    let agent: AgentService
    let agentPanel: AgentPanelController
    let updater = UpdaterService()

    let frontmostTracker = FrontmostApplicationTracker()

    /// Set by the status item controller, which owns the popover.
    var onTogglePanel: (() -> Void)?

    private init() {
        let preferences = Preferences()
        let tracker = frontmostTracker
        self.preferences = preferences
        self.permission = .shared
        self.screenRecordingPermission = .shared
        self.permissionCatalog = PermissionCatalog()

        let windowManager = WindowManagerService(preferences: preferences, frontmostTracker: tracker)
        self.windowManager = windowManager
        self.layouts = WorkspaceLayoutStore()
        self.windowRules = WindowRuleStore(windowManager: windowManager)
        self.dragSnap = DragSnapController(preferences: preferences, windowManager: windowManager)

        let clipboard = ClipboardService(preferences: preferences)
        self.clipboard = clipboard
        self.monitor = SystemMonitorService()
        self.keepAwake = KeepAwakeService(preferences: preferences)

        let thumbnails = WindowThumbnailService()
        self.thumbnails = thumbnails
        self.calendar = CalendarService()

        self.clipboardPanel = ClipboardPanelController(
            service: clipboard,
            preferences: preferences,
            frontmostTracker: tracker
        )
        self.windowSwitcher = WindowSwitcherPanelController(
            preferences: preferences,
            frontmostTracker: tracker,
            thumbnails: thumbnails
        )
        self.dockPreview = DockPreviewController(
            thumbnails: thumbnails,
            preferences: preferences
        )
        self.customDock = DockReplacementController(preferences: preferences)

        let shelf = ShelfStore()
        self.shelf = shelf
        let downloads = DownloadCoordinator(preferences: preferences, frontmostTracker: tracker)
        self.downloads = downloads
        let audioMixer = AudioMixerService(preferences: preferences)
        self.audioMixer = audioMixer
        let displayBrightness = DisplayBrightnessService()
        self.displayBrightness = displayBrightness
        self.notchPanel = NotchWindowController(
            shelf: shelf,
            downloads: downloads.store,
            calendar: calendar,
            mixer: audioMixer,
            brightness: displayBrightness,
            preferences: preferences
        )
        self.menuPalette = MenuPalettePanelController(frontmostTracker: tracker)

        let menuBarManager = MenuBarManagerService(preferences: preferences)
        self.menuBarManager = menuBarManager
        self.hiddenItemsBar = HiddenItemsBarController(service: menuBarManager)
        self.menuBarSearch = MenuBarSearchPanelController(service: menuBarManager)
        self.menuBarAppearance = MenuBarAppearanceOverlay(preferences: preferences)

        self.hardware = HardwareService()
        let helperInstaller = HelperInstaller()
        self.helperInstaller = helperInstaller
        self.chargeLimit = ChargeLimitService(preferences: preferences, installer: helperInstaller)
        let quickNote = QuickNotePanelController(shelf: shelf, frontmostTracker: tracker)
        self.quickNote = quickNote
        self.presentation = PresentationModeService(
            preferences: preferences,
            keepAwake: keepAwake,
            notchPanel: notchPanel
        )
        self.onboarding = OnboardingWindowController(
            catalog: permissionCatalog,
            preferences: preferences
        )

        // The assistant is a language interface over what this app already does, so its toolbox is
        // handed the same services everything else uses rather than reaching for its own.
        let agent = AgentService(
            preferences: preferences,
            toolbox: AgentToolbox(shelf: shelf, clipboard: clipboard)
        )
        self.agent = agent
        self.agentPanel = AgentPanelController(service: agent)

        // The moment's context, read from what the dock already polls rather than asked for again:
        // going and finding out would mean a subprocess on the way to every message.
        agent.contextReader = { [weak self] in
            guard let self else { return AgentContext() }
            return AgentContextReader.read(
                dock: customDock.model,
                isDockRunning: preferences.isEnabled(.dock) && preferences.isCustomDockEnabled
            )
        }

        menuBarManager.onToggleHiddenItemsBar = { [weak self] in self?.hiddenItemsBar.toggle() }
        menuBarManager.onHideHiddenItemsBar = { [weak self] in self?.hiddenItemsBar.hide() }
        menuBarManager.onSearchItems = { [weak self] in self?.menuBarSearch.toggle() }
        menuBarManager.onOpenSettings = { SettingsWindow.open() }

        // The queue reports through the island, and the island hands links back to the queue.
        downloads.onAnnounce = { [weak self] activity in self?.notchPanel.announce(activity) }
        downloads.onOffer = { [weak self] offer in self?.notchPanel.presentOffer(offer) }
        downloads.onWillPlaceFile = { [weak self] name in
            self?.notchPanel.island.claimIncomingFile(name)
        }
        notchPanel.island.onDroppedLink = { [weak self] url in self?.downloads.promptForLink(url) }
        notchPanel.island.onOpenDownloadPrompt = { [weak self] in self?.downloads.showPending() }
        notchPanel.island.onEnterLinkManually = { [weak self] in self?.downloads.showManualEntry() }
        // The extension is the only thing that can say which tab is making sound.
        downloads.bridge.onPlaying = { [weak self] playback in
            self?.notchPanel.setBrowserPlayback(playback)
        }

        // The bar's own button opens the popover, the same as clicking the status item.
        customDock.onOpenPanel = { [weak self] in self?.onTogglePanel?() }
        // Hovering an icon of our own shows that app's windows, the way hovering the system Dock did.
        customDock.previews = dockPreview
        // The bar shows how far the queue has got; the queue itself stays the downloads module's.
        customDock.downloads = downloads.store
        // The bar's assistant button opens the chat, which belongs to the agent rather than the dock.
        customDock.onShowAgent = { [weak self] anchor, style in
            self?.agentPanel.toggle(anchor: anchor, style: style)
        }
        // Dropped files go to the agent and the panel opens on them — shown, not sent: what to do
        // with a file is the half of the request that is still being typed.
        // A strip that parks itself must not do it while its own chat is standing open on it.
        customDock.isAgentPanelVisible = { [weak self] in self?.agentPanel.isVisible ?? false }
        customDock.onAcceptFiles = { [weak self] urls, anchor, style in
            guard let self else { return }
            agent.attach(urls)
            if !agentPanel.isVisible { agentPanel.show(anchor: anchor, style: style) }
        }

        quickNote.onSaved = { [weak self] in self?.notchPanel.announce(.filesAdded(1)) }
        keepAwake.onSleepDespiteSession = { [weak self] in
            self?.notchPanel.announce(.sleepDespiteKeepAwake)
        }
    }

    func start() {
        // Before anything else: a Mac left without a Dock by a previous run gets it back.
        customDock.recoverIfNeeded()

        // Things that belong to the app rather than to any one part of it.
        audioMixer.applyPersistedVolumes()
        menuBarAppearance.start()
        observeAccessibility()

        applyModules()
        onboarding.showIfFirstLaunch()
    }

    /// Brings every service into line with which modules are switched on.
    ///
    /// The single authority on that question, and deliberately the only one: a module switch that
    /// each service interpreted for itself would be a switch nobody could reason about. Called at
    /// launch and after any change, and it is idempotent — running it twice leaves the app in the
    /// same state as running it once.
    ///
    /// Switching a module off releases what it was holding rather than merely hiding it: the
    /// samplers stop, the observers come off, the status items go back, and its global shortcuts
    /// are handed back to the system.
    func applyModules() {
        func on(_ module: AppModule) -> Bool { preferences.isEnabled(module) }

        clipboard.stop()
        if on(.clipboard) { clipboard.start() }

        if on(.windows) {
            windowRules.start()
            dragSnap.updateMonitoring()
        } else {
            windowRules.stop()
            dragSnap.stop()
        }

        if on(.notch) { notchPanel.updateMonitoring() } else { notchPanel.stop() }
        if on(.dockPreviews) { dockPreview.updateMonitoring() } else { dockPreview.stop() }
        // The Dock's own settings are not something this app holds open, so switching the module
        // off has to hand them back rather than merely stop showing them.
        dockTweaks.moduleDidChange(isEnabled: on(.dock))
        customDock.updateState()

        // The manager reads its own switch, which is the module's switch.
        menuBarManager.start()

        // A hold on sleep that outlives the feature holding it would be a Mac that will not
        // sleep for no visible reason.
        if on(.keepAwake) {
            keepAwake.start()
        } else if keepAwake.isActive {
            keepAwake.toggle()
        }

        if on(.hardware) { chargeLimit.start() } else { chargeLimit.updateConfiguration() }

        downloads.updateMonitoring()
        updateMonitorMode(isPopoverOpen: false)
        registerShortcuts()
    }

    /// Features gated on Accessibility start themselves the moment it is granted, without a
    /// relaunch. Observation fires once per change, so the observer re-arms itself.
    private func observeAccessibility() {
        withObservationTracking {
            _ = permission.isTrusted
        } onChange: {
            Task { @MainActor [weak self] in
                self?.permissionsChanged()
                self?.observeAccessibility()
            }
        }
    }

    /// Re-applies every binding. Called on launch and whenever a shortcut is edited.
    ///
    /// A module that is switched off holds none of its keys: leaving them registered would take a
    /// system-wide combination away from every other app on behalf of something the user has
    /// turned off.
    func registerShortcuts() {
        HotKeyManager.shared.unregisterAll()
        for action in HotKeyAction.allCases {
            guard preferences.ownsShortcut(for: action) else { continue }
            guard let combo = preferences.shortcut(for: action) else { continue }
            HotKeyManager.shared.register(combo, for: action) { [weak self] in
                self?.perform(action)
            }
        }
    }

    func updateMonitorMode(isPopoverOpen: Bool) {
        // A sampler belonging to a module that is off is a timer nobody asked for, whatever else
        // is on screen.
        monitor.setMode(preferences.isEnabled(.systemMonitor) ? monitorMode(isPopoverOpen) : .suspended)
        hardware.setMode(preferences.isEnabled(.hardware) ? sensorMode(isPopoverOpen) : .suspended)
    }

    private func monitorMode(_ isPopoverOpen: Bool) -> SystemMonitorService.Mode {
        guard !isPopoverOpen else { return .detailed }
        return preferences.menuBarMetric == .none ? .suspended : .background
    }

    /// Sensors are only read when something is showing them; the charge limit keeps its own, much
    /// cheaper, eye on the battery.
    private func sensorMode(_ isPopoverOpen: Bool) -> HardwareService.Mode {
        guard !isPopoverOpen else { return .detailed }
        return preferences.menuBarMetric.needsSensors ? .background : .suspended
    }

    /// Re-evaluates every feature that depends on Accessibility being granted.
    func permissionsChanged() {
        dockPreview.updateMonitoring()
        dragSnap.updateMonitoring()
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .window(let windowAction):
            windowManager.perform(windowAction)
        case .layout(let slot):
            layouts.apply(slot: slot)
        case .showClipboard:
            clipboardPanel.toggle()
        case .switchWindows:
            windowSwitcher.handleShortcut()
        case .togglePanel:
            onTogglePanel?()
        case .toggleKeepAwake:
            keepAwake.toggle()
        case .toggleMicMute:
            // nil means the toggle failed (no input device or mute not settable):
            // never announce a state that did not actually change.
            if let muted = SystemAudio.toggleInputMute() {
                notchPanel.announce(.micStatus(muted: muted))
            }
        case .captureText:
            Task { [weak self] in
                guard let characters = await ScreenTextCapture.capture() else { return }
                self?.notchPanel.announce(.textCaptured(characters))
            }
        case .searchMenus:
            menuPalette.toggle()
        case .quickNote:
            quickNote.toggle()
        case .togglePresentation:
            presentation.toggle()
        case .rescueWindows:
            let rescued = WindowRescuer.rescueOffscreenWindows()
            notchPanel.announce(.windowsRescued(rescued))
        case .toggleHiddenItems:
            menuBarManager.toggleHiddenItems()
        case .searchMenuBarItems:
            menuBarSearch.toggle()
        }
    }
}
