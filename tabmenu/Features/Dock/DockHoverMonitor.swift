//
//  DockHoverMonitor.swift
//  tabmenu
//

import AppKit

/// Watches the pointer and reports which Dock icon it is over.
///
/// Mouse-moved events arrive at display rate, so the work is tiered: a cached Dock frame
/// rejects most events immediately, and the icon list is only re-read while the pointer is
/// actually inside the Dock.
@MainActor
final class DockHoverMonitor {
    /// Reports every move with the icon under the pointer, if any.
    var onMove: ((_ location: CGPoint, _ item: DockItem?) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var cachedDockFrame: CGRect?
    private var dockFrameRefreshedAt = Date.distantPast
    private var cachedItems: [DockItem] = []
    private var itemsRefreshedAt = Date.distantPast

    private static let dockFrameTTL: TimeInterval = 2
    private static let itemsTTL: TimeInterval = 0.75

    func start() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cachedItems = []
        cachedDockFrame = nil
    }

    private func handle(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        let accessibilityPoint = location.inAccessibilitySpace

        guard let dockFrame = dockFrame(), dockFrame.insetBy(dx: -8, dy: -8).contains(accessibilityPoint) else {
            onMove?(location, nil)
            return
        }

        let item = items().first { $0.frame.contains(accessibilityPoint) }
        onMove?(location, item)
    }

    private func dockFrame() -> CGRect? {
        if Date().timeIntervalSince(dockFrameRefreshedAt) > Self.dockFrameTTL {
            cachedDockFrame = DockItemLister.dockFrame()
            dockFrameRefreshedAt = Date()
        }
        return cachedDockFrame
    }

    private func items() -> [DockItem] {
        if Date().timeIntervalSince(itemsRefreshedAt) > Self.itemsTTL {
            cachedItems = DockItemLister.applicationItems()
            itemsRefreshedAt = Date()
        }
        return cachedItems
    }
}
