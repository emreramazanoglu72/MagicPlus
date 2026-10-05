//
//  HiddenItemsBarController.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// A strip under the menu bar carrying the hidden items, for when the bar itself has no
/// room left to fold them back into — a notched display with a wide app menu, typically.
/// Clicking an item there clicks the real thing.
@MainActor
final class HiddenItemsBarController: NSObject {
    private let service: MenuBarManagerService

    private var panel: NSPanel?
    private var dismissMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var isLive = false

    private static let itemWidth: CGFloat = 30
    private static let height: CGFloat = 34
    private static let horizontalPadding: CGFloat = 10
    private static let gapBelowMenuBar: CGFloat = 4

    init(service: MenuBarManagerService) {
        self.service = service
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        service.refreshItems()
        let items = hiddenItems
        guard !items.isEmpty else {
            // Nothing to show would leave an empty sliver on screen, so the bar falls back
            // to the plain reveal and the user still gets an answer to their click.
            service.reveal(.hidden)
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, itemCount: items.count)
        panel.orderFrontRegardless()

        startDismissMonitor()
        if !isLive {
            isLive = true
            service.startLiveUpdates()
        }
    }

    func hide() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        stopDismissMonitor()
        if isLive {
            isLive = false
            service.stopLiveUpdates()
        }
    }

    private var hiddenItems: [MenuBarItem] {
        service.items(in: .hidden) + service.items(in: .alwaysHidden)
    }

    private func makePanel() -> NSPanel {
        FloatingPanel.makeNonActivating(
            size: CGSize(width: 200, height: Self.height),
            content: HiddenItemsBarView(
                service: service,
                onActivate: { [weak self] item in
                    self?.hide()
                    self?.service.activate(item)
                },
                onSearch: { [weak self] in
                    self?.hide()
                    self?.service.onSearchItems?()
                }
            )
        )
    }

    /// Pinned to the right of the display holding the pointer, just under its menu bar, so
    /// it lands where the items themselves would have been.
    private func position(_ panel: NSPanel, itemCount: Int) {
        guard let screen = MenuBarGeometry.screenContainingPointer() else { return }
        let menuBar = MenuBarGeometry.menuBarFrame(for: screen)
        let contentWidth = CGFloat(itemCount) * Self.itemWidth + Self.horizontalPadding * 2 + Self.itemWidth
        let width = min(contentWidth, screen.frame.width - 40)

        panel.setFrame(
            CGRect(
                x: menuBar.maxX - width - 8,
                y: menuBar.minY - Self.height - Self.gapBelowMenuBar,
                width: width,
                height: Self.height
            ),
            display: true
        )
    }

    private func startDismissMonitor() {
        if dismissMonitor == nil {
            dismissMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideIfPointerIsOutside() }
            }
        }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    private func hideIfPointerIsOutside() {
        guard let frame = panel?.frame, !frame.contains(NSEvent.mouseLocation) else { return }
        hide()
    }

    private func stopDismissMonitor() {
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }
}

/// The strip itself: every hidden item, in the order the menu bar holds them.
struct HiddenItemsBarView: View {
    let service: MenuBarManagerService
    let onActivate: (MenuBarItem) -> Void
    let onSearch: () -> Void

    @State private var hoveredItem: CGWindowID?

    private var items: [MenuBarItem] {
        service.items(in: .hidden) + service.items(in: .alwaysHidden)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Button {
                    onActivate(item)
                } label: {
                    MenuBarItemIcon(item: item, images: service.images)
                        .padding(3)
                        .background(
                            .quaternary.opacity(hoveredItem == item.id ? 0.8 : 0),
                            in: .rect(cornerRadius: 6)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? item.id : nil }
                .help(item.displayName)
            }

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text("Search menu bar items"))
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(in: .rect(cornerRadius: 11))
        .motion(Motion.snappy, value: hoveredItem)
    }
}
