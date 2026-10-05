//
//  MenuBarManagerService.swift
//  tabmenu
//

import AppKit
import Observation
import os

/// Cuts the menu bar into sections and drives everything that shows what is in them.
///
/// Two status items of its own do the work: a chevron the user clicks, and a divider that
/// grows wide enough to push the items on its left out of the bar. Which section an item is
/// in follows from where it sits, so the user arranges the bar by ⌘-dragging items across
/// the divider — the same gesture macOS already provides — and nothing is ever moved,
/// rewritten or destroyed on their behalf.
@Observable
@MainActor
final class MenuBarManagerService {
    /// Every item in the bar, this app's own control items included, left to right.
    private(set) var items: [MenuBarItem] = []
    private(set) var revealedSections: Set<MenuBarSection> = []
    /// False until the dividers exist, which is what makes every item read as visible while
    /// the feature is switched off.
    private(set) var hasControlItems = false

    let images: MenuBarItemImageCache

    /// Raised when the chevron is clicked and the hidden items belong in the floating bar
    /// rather than back in the menu bar.
    @ObservationIgnored var onToggleHiddenItemsBar: (() -> Void)?
    @ObservationIgnored var onHideHiddenItemsBar: (() -> Void)?
    @ObservationIgnored var onSearchItems: (() -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let permission: AccessibilityPermission
    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "MenuBar")

    @ObservationIgnored private var chevron: MenuBarControlItem?
    @ObservationIgnored private var hiddenDivider: MenuBarControlItem?
    @ObservationIgnored private var alwaysHiddenDivider: MenuBarControlItem?

    @ObservationIgnored private var pointerMonitors: [Any] = []
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var rehideTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTimer: Timer?
    /// Surfaces that want a live list; the polling timer runs while at least one is open.
    @ObservationIgnored private var liveObservers = 0

    private static let layoutSettleDelay: Duration = .milliseconds(180)
    /// Long enough that the pointer clipping the edge of the bar does not fold it away.
    private static let pointerGrace: Duration = .milliseconds(700)
    private static let refreshInterval: TimeInterval = 1.5

    init(preferences: Preferences, permission: AccessibilityPermission? = nil, images: MenuBarItemImageCache? = nil) {
        self.preferences = preferences
        self.permission = permission ?? .shared
        self.images = images ?? MenuBarItemImageCache()
    }

    // MARK: - Lifecycle

    func start() {
        updateConfiguration()
    }

    /// Re-reads every preference the feature depends on. Called at launch and whenever one
    /// of them is edited.
    func updateConfiguration() {
        if preferences.isMenuBarManagerEnabled {
            installControlItems()
        } else {
            removeControlItems()
        }
        updateMonitoring()
        refreshItems()
    }

    private func installControlItems() {
        // Created right to left, so a first launch lands them in the order they are read in:
        // always-hidden divider, hidden divider, chevron.
        if chevron == nil {
            let item = MenuBarControlItem(
                role: .chevron,
                autosaveName: "MagicPlusMenuBarChevron",
                isCollapsed: !preferences.isHiddenSectionRevealed
            )
            item.onClick = { [weak self] event in self?.handleChevronClick(event) }
            chevron = item
        }
        if hiddenDivider == nil {
            let item = MenuBarControlItem(
                role: .divider,
                autosaveName: "MagicPlusMenuBarDivider",
                isCollapsed: !preferences.isHiddenSectionRevealed
            )
            item.onClick = { [weak self] _ in self?.reveal(.hidden) }
            hiddenDivider = item
        }
        if preferences.usesAlwaysHiddenSection {
            if alwaysHiddenDivider == nil {
                let item = MenuBarControlItem(
                    role: .divider,
                    autosaveName: "MagicPlusMenuBarAlwaysHiddenDivider",
                    isCollapsed: false
                )
                item.onClick = { [weak self] _ in self?.reveal(.alwaysHidden) }
                alwaysHiddenDivider = item
            }
        } else {
            alwaysHiddenDivider?.remove()
            alwaysHiddenDivider = nil
            revealedSections.remove(.alwaysHidden)
        }

        hasControlItems = true
        if preferences.isHiddenSectionRevealed {
            revealedSections.insert(.hidden)
        }
        applySectionState()
    }

    private func removeControlItems() {
        chevron?.remove()
        hiddenDivider?.remove()
        alwaysHiddenDivider?.remove()
        chevron = nil
        hiddenDivider = nil
        alwaysHiddenDivider = nil
        hasControlItems = false
        revealedSections.removeAll()
        cancelPendingWork()
    }

    // MARK: - Sections

    func isRevealed(_ section: MenuBarSection) -> Bool {
        section == .visible || revealedSections.contains(section)
    }

    func toggle(_ section: MenuBarSection) {
        setRevealed(!isRevealed(section), for: section)
    }

    func reveal(_ section: MenuBarSection) {
        setRevealed(true, for: section)
    }

    func setRevealed(_ revealed: Bool, for section: MenuBarSection) {
        guard section.isCollapsible, hasControlItems else { return }

        if revealed {
            revealedSections.insert(section)
            // The always-hidden items sit on the far side of the hidden ones, so they can
            // only come into view once the hidden section is out of the way too.
            if section == .alwaysHidden { revealedSections.insert(.hidden) }
        } else {
            revealedSections.remove(section)
            if section == .hidden { revealedSections.remove(.alwaysHidden) }
        }

        if section == .hidden { preferences.isHiddenSectionRevealed = revealed }
        applySectionState()
        scheduleAutomaticRehide()
        refreshItemsAfterLayout()
    }

    /// Reveals a section without recording it as the user's preferred resting state, for
    /// clicks that come from the floating bar or the search panel.
    func revealTemporarily(_ section: MenuBarSection) {
        guard section.isCollapsible, hasControlItems, !isRevealed(section) else { return }
        revealedSections.insert(section)
        if section == .alwaysHidden { revealedSections.insert(.hidden) }
        applySectionState()
        scheduleAutomaticRehide()
    }

    func collapseAll() {
        guard hasControlItems, !revealedSections.isEmpty else { return }
        revealedSections.removeAll()
        preferences.isHiddenSectionRevealed = false
        applySectionState()
        refreshItemsAfterLayout()
    }

    private func applySectionState() {
        let isHiddenRevealed = revealedSections.contains(.hidden)
        let isAlwaysHiddenRevealed = revealedSections.contains(.alwaysHidden)

        chevron?.setCollapsed(!isHiddenRevealed)
        hiddenDivider?.setCollapsed(!isHiddenRevealed)
        // Only the rightmost collapsed divider has to grow: anything further left is already
        // outside the bar, and a second wide item would push the hidden section out with it.
        alwaysHiddenDivider?.setCollapsed(isHiddenRevealed && !isAlwaysHiddenRevealed)

        if !isHiddenRevealed { onHideHiddenItemsBar?() }
    }

    // MARK: - Items

    func refreshItems() {
        items = MenuBarItemLister.items()
        images.refresh(for: items(in: .hidden) + items(in: .alwaysHidden))
    }

    /// The bar needs a moment to lay itself out again before the new positions can be read.
    private func refreshItemsAfterLayout() {
        Task { [weak self] in
            try? await Task.sleep(for: Self.layoutSettleDelay)
            self?.refreshItems()
        }
    }

    func section(of item: MenuBarItem) -> MenuBarSection {
        MenuBarLayout.section(
            itemMinX: item.frame.minX,
            hiddenDividerMinX: hiddenDivider?.minX,
            alwaysHiddenDividerMinX: alwaysHiddenDivider?.minX
        )
    }

    /// The items a person would recognise: this app's own dividers are part of the
    /// machinery, not part of the bar.
    func items(in section: MenuBarSection) -> [MenuBarItem] {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return items.filter { item in
            item.processIdentifier != ownProcessIdentifier && self.section(of: item) == section
        }
    }

    var hiddenItemCount: Int { items(in: .hidden).count + items(in: .alwaysHidden).count }

    /// Clicks an item wherever it currently is, bringing its section into the bar first: an
    /// item that has been pushed out of the bar has no position left to click.
    func activate(_ item: MenuBarItem, secondary: Bool = false) {
        guard permission.isTrusted else {
            permission.request()
            return
        }

        let section = section(of: item)
        Task { [weak self] in
            guard let self else { return }
            if section.isCollapsible, !self.isRevealed(section) {
                self.revealTemporarily(section)
                try? await Task.sleep(for: Self.layoutSettleDelay)
            }
            self.refreshItems()
            guard let current = self.items.first(where: { $0.key == item.key }), current.frame.width > 1 else {
                self.logger.notice("menu bar item vanished before it could be clicked")
                return
            }
            MenuBarItemActivator.click(at: current.center, secondary: secondary)
            self.scheduleAutomaticRehide()
        }
    }

    // MARK: - Live updates

    /// Kept simple on purpose: the window server has no change notification for menu bar
    /// items, so surfaces that show them poll while they are open and stop when they close.
    func startLiveUpdates() {
        liveObservers += 1
        refreshItems()
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshItems() }
        }
    }

    func stopLiveUpdates() {
        liveObservers = max(0, liveObservers - 1)
        guard liveObservers == 0 else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Chevron

    private func handleChevronClick(_ event: NSEvent) {
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showChevronMenu()
        } else if event.modifierFlags.contains(.option), preferences.usesAlwaysHiddenSection {
            toggle(.alwaysHidden)
        } else if preferences.usesHiddenItemsBar, !isRevealed(.hidden) {
            onToggleHiddenItemsBar?()
        } else {
            toggle(.hidden)
        }
    }

    private func showChevronMenu() {
        refreshItems()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(
            title: isRevealed(.hidden)
                ? String(localized: "Hide Menu Bar Items", comment: "Chevron menu")
                : String(localized: "Show Menu Bar Items", comment: "Chevron menu"),
            handler: { [weak self] in self?.toggle(.hidden) }
        ))
        if preferences.usesAlwaysHiddenSection {
            menu.addItem(ClosureMenuItem(
                title: String(localized: "Show Always-Hidden Items", comment: "Chevron menu"),
                state: isRevealed(.alwaysHidden) ? .on : .off,
                handler: { [weak self] in self?.toggle(.alwaysHidden) }
            ))
        }
        menu.addItem(ClosureMenuItem(
            title: String(localized: "Search Menu Bar Items…", comment: "Chevron menu"),
            handler: { [weak self] in self?.onSearchItems?() }
        ))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(
            title: String(localized: "Menu Bar Settings…", comment: "Chevron menu"),
            handler: { [weak self] in self?.onOpenSettings?() }
        ))
        chevron?.showMenu(menu)
    }

    /// What the global shortcut and the popover button both call.
    func toggleHiddenItems() {
        guard hasControlItems else { return }
        if preferences.usesHiddenItemsBar, !isRevealed(.hidden) {
            onToggleHiddenItemsBar?()
        } else {
            toggle(.hidden)
        }
    }

    // MARK: - Rehiding

    private func scheduleAutomaticRehide() {
        rehideTask?.cancel()
        rehideTask = nil
        guard hasControlItems, !revealedSections.isEmpty else { return }

        switch preferences.menuBarRehideStrategy {
        case .never, .focusedApp:
            return
        case .pointerLeaves:
            guard !MenuBarGeometry.isInsideMenuBar(NSEvent.mouseLocation) else { return }
            scheduleRehide(after: Self.pointerGrace)
        case .timed:
            scheduleRehide(after: .seconds(preferences.menuBarRehideDelay))
        }
    }

    private func scheduleRehide(after delay: Duration) {
        rehideTask?.cancel()
        rehideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // Folding the bar back moves whichever item a menu belongs to, which would close
            // the menu the user is reading, so the wait continues until it is dismissed.
            while MenuBarItemLister.isPopUpMenuOpen() {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
            self?.collapseAll()
        }
    }

    private func cancelPendingWork() {
        rehideTask?.cancel()
        rehideTask = nil
        hoverTask?.cancel()
        hoverTask = nil
    }

    // MARK: - Monitoring

    /// Pointer tracking is only worth its cost when a preference actually asks for it.
    func updateMonitoring() {
        let needsPointer = preferences.isMenuBarManagerEnabled
            && (preferences.menuBarShowsOnHover || preferences.menuBarRehideStrategy == .pointerLeaves)
        needsPointer ? startPointerMonitoring() : stopPointerMonitoring()

        let needsActivation = preferences.isMenuBarManagerEnabled
            && preferences.menuBarRehideStrategy == .focusedApp
        needsActivation ? startActivationObserver() : stopActivationObserver()
    }

    private func startPointerMonitoring() {
        guard pointerMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePointerMoved() }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointerMoved() }
            return event
        }) {
            pointerMonitors.append(local)
        }
    }

    private func stopPointerMonitoring() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
    }

    private func handlePointerMoved() {
        let isInside = MenuBarGeometry.isInsideMenuBar(NSEvent.mouseLocation)

        if isInside {
            rehideTask?.cancel()
            rehideTask = nil
            if preferences.menuBarShowsOnHover, !isRevealed(.hidden), hoverTask == nil {
                scheduleHoverReveal()
            }
        } else {
            hoverTask?.cancel()
            hoverTask = nil
            if preferences.menuBarRehideStrategy == .pointerLeaves, !revealedSections.isEmpty, rehideTask == nil {
                scheduleRehide(after: Self.pointerGrace)
            }
        }
    }

    private func scheduleHoverReveal() {
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.hoverTask = nil
            guard MenuBarGeometry.isInsideMenuBar(NSEvent.mouseLocation) else { return }
            self.revealTemporarily(.hidden)
            self.refreshItemsAfterLayout()
        }
    }

    private func startActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, !self.revealedSections.isEmpty else { return }
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard application?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.scheduleRehide(after: .milliseconds(120))
            }
        }
    }

    private func stopActivationObserver() {
        guard let activationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        self.activationObserver = nil
    }
}
