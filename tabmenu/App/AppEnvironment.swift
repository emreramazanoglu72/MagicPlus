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
    let clipboardPanel: ClipboardPanelController
    let windowSwitcher: WindowSwitcherPanelController
    let dockPreview: DockPreviewController
    let audioMixer: AudioMixerService
    let displayBrightness: DisplayBrightnessService
    let notchPanel: NotchWindowController
    let menuPalette: MenuPalettePanelController
    let quickNote: QuickNotePanelController
    let presentation: PresentationModeService
    let onboarding: OnboardingWindowController
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

        let shelf = ShelfStore()
        self.shelf = shelf
        let audioMixer = AudioMixerService(preferences: preferences)
        self.audioMixer = audioMixer
        let displayBrightness = DisplayBrightnessService()
        self.displayBrightness = displayBrightness
        self.notchPanel = NotchWindowController(
            shelf: shelf,
            calendar: calendar,
            mixer: audioMixer,
            brightness: displayBrightness,
            preferences: preferences
        )
        self.menuPalette = MenuPalettePanelController(frontmostTracker: tracker)
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

        quickNote.onSaved = { [weak self] in self?.notchPanel.announce(.filesAdded(1)) }
        keepAwake.onSleepDespiteSession = { [weak self] in
            self?.notchPanel.announce(.sleepDespiteKeepAwake)
        }
    }

    func start() {
        clipboard.start()
        registerShortcuts()
        updateMonitorMode(isPopoverOpen: false)
        dockPreview.updateMonitoring()
        notchPanel.updateMonitoring()
        dragSnap.updateMonitoring()
        keepAwake.start()
        windowRules.start()
        audioMixer.applyPersistedVolumes()
        observeAccessibility()
        onboarding.showIfFirstLaunch()
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
    func registerShortcuts() {
        HotKeyManager.shared.unregisterAll()
        for action in HotKeyAction.allCases {
            guard let combo = preferences.shortcut(for: action) else { continue }
            HotKeyManager.shared.register(combo, for: action) { [weak self] in
                self?.perform(action)
            }
        }
    }

    func updateMonitorMode(isPopoverOpen: Bool) {
        if isPopoverOpen {
            monitor.setMode(.detailed)
        } else {
            monitor.setMode(preferences.menuBarMetric == .none ? .suspended : .background)
        }
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
        }
    }
}
