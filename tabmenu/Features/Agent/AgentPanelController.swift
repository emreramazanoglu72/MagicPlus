//
//  AgentPanelController.swift
//  MagicPlus
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The chat panel behind the agent button in the bar.
///
/// The same shape as the start menu, because it opens from the same place and should feel like the
/// same furniture: anchored to the button that was clicked, closed by Escape, by clicking anywhere
/// else, or by losing key status to another application. The conversation survives closing — the
/// panel hides, the service keeps the transcript — so a glance away does not cost an answer.
@MainActor
final class AgentPanelController: NSObject, NSWindowDelegate {
    private let service: AgentService
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let outsideClicks = OutsideClickMonitor()

    private static let size = CGSize(width: 400, height: 540)
    private static let minimumSize = CGSize(width: 340, height: 320)
    /// Remembered across openings. A panel that forgets the size it was dragged to is a panel that
    /// gets dragged to the same size every time.
    private static let sizeKey = "agent.panelSize"

    private var rememberedSize: CGSize {
        let stored = UserDefaults.standard.dictionary(forKey: Self.sizeKey) as? [String: Double]
        guard let width = stored?["w"], let height = stored?["h"] else { return Self.size }
        return CGSize(
            width: max(Self.minimumSize.width, width),
            height: max(Self.minimumSize.height, height)
        )
    }

    init(service: AgentService) {
        self.service = service
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(anchor: CGRect, style: DockStyle) {
        isVisible ? hide() : show(anchor: anchor, style: style)
    }

    func show(anchor: CGRect, style: DockStyle) {
        service.panelStyle = style

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, anchor: anchor, edge: style.edge)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startKeyMonitor()
        // Pinned, a click elsewhere is somebody getting on with the thing they asked about.
        outsideClicks.start(panel: panel, anchor: anchor) { [weak self] in
            guard let self, !service.isPinned else { return }
            hide()
        }
    }

    func hide() {
        stopKeyMonitor()
        outsideClicks.stop()
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel, anchor: CGRect, edge: DockStyle.Edge) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        else { return }
        // Whatever size it is now, which after a drag is not the size it shipped with.
        let size = panel.frame.size == .zero ? rememberedSize : panel.frame.size
        let gap: CGFloat = 8
        var origin: CGPoint = switch edge {
        case .bottom: CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        case .top: CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - gap)
        }
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: rememberedSize),
            // Resizable, because a long answer — or any code at all — in a four-hundred-point
            // window is an answer nobody can read.
            styleMask: [.titled, .fullSizeContentView, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = Self.minimumSize
        // Movable once it is pinned: something that stays open is something people put somewhere.
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: AgentChatView(service: service))
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !service.isPinned else { return }
        hide()
    }

    /// Kept, so the next opening is the size this one was left at.
    func windowDidResize(_ notification: Notification) {
        guard let size = panel?.frame.size else { return }
        UserDefaults.standard.set(["w": size.width, "h": size.height], forKey: Self.sizeKey)
    }

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard let self, isVisible else { return event }

            switch Int(event.keyCode) {
            case kVK_Escape:
                hide()
                return nil
            // The terminal habit, and the right one here: the previous message comes back to be
            // edited rather than retyped. Only on an empty field, where the arrow has nothing else
            // to do — with text in it, moving the caret is what it is for.
            case kVK_UpArrow where service.draft.isEmpty:
                guard let last = service.lastMessage else { return event }
                service.draft = last
                return nil
            default:
                return event
            }
        })
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
