//
//  VolumePanel.swift
//  MagicPlus
//

import AppKit
import Observation
import SwiftUI

/// The volume control behind the speaker in the bar.
///
/// It used to open the app's whole popover, which is not what a speaker icon promises. A click on a
/// speaker should give you a slider, so this is a slider.
@MainActor
final class VolumePanel: NSObject, NSWindowDelegate {
    @Observable
    @MainActor
    final class Model {
        var level: Double = 0.5
        /// Remembered so unmuting returns to where it was rather than to something arbitrary.
        var levelBeforeMute: Double = 0.5

        func read() {
            level = SystemAudio.outputVolume() ?? level
            if level > 0 { levelBeforeMute = level }
        }

        func apply(_ value: Double) {
            level = value
            if value > 0 { levelBeforeMute = value }
            SystemAudio.setOutputVolume(value)
        }

        func toggleMute() {
            apply(level > 0 ? 0 : max(0.1, levelBeforeMute))
        }
    }

    private let model = Model()
    private var panel: NSPanel?
    private let outsideClicks = OutsideClickMonitor()

    private static let size = CGSize(width: 240, height: 62)

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(anchor: CGRect, edge: DockStyle.Edge) {
        isVisible ? hide() : show(anchor: anchor, edge: edge)
    }

    func show(anchor: CGRect, edge: DockStyle.Edge) {
        model.read()

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, anchor: anchor, edge: edge)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // The same reason as the start menu: the bar never takes key status, so clicking it would
        // otherwise leave the slider open on top of the dock.
        outsideClicks.start(panel: panel, anchor: anchor) { [weak self] in self?.hide() }
    }

    func hide() {
        outsideClicks.stop()
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel, anchor: CGRect, edge: DockStyle.Edge) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        else { return }
        let gap: CGFloat = 8
        var origin: CGPoint = switch edge {
        case .bottom: CGPoint(x: anchor.midX - Self.size.width / 2, y: anchor.maxY + gap)
        case .top: CGPoint(x: anchor.midX - Self.size.width / 2, y: anchor.minY - Self.size.height - gap)
        }
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - Self.size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel.make(
            size: Self.size,
            title: String(localized: "Sound", comment: "Volume panel title"),
            content: VolumeView(model: model)
        )
        panel.delegate = self
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}

private struct VolumeView: View {
    let model: VolumePanel.Model

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleMute()
            } label: {
                Image(systemName: model.level == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Slider(value: Binding(get: { model.level }, set: { model.apply($0) }), in: 0...1)

            Text("\(Int(model.level * 100))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(.ultraThickMaterial)
    }
}
