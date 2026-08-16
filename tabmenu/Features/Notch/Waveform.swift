//
//  Waveform.swift
//  tabmenu
//

import SwiftUI

/// Animated level bars used as a live playback indicator.
///
/// The animation only runs while audio is actually playing — a looping animation is a status
/// signal here, not decoration — and freezes into a flat state when paused or when the system
/// asks for reduced motion.
struct Waveform: View {
    var isPlaying: Bool
    var tint: Color = .white
    var barCount = 4
    var height: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAnimating: Bool { isPlaying && !reduceMotion }

    var body: some View {
        Group {
            if isAnimating {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    bars(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(at: nil)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func bars(at time: TimeInterval?) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5, height: barHeight(index: index, time: time))
            }
        }
    }

    /// Each bar runs the same wave at its own phase, so the group reads as a level meter.
    private func barHeight(index: Int, time: TimeInterval?) -> CGFloat {
        guard let time else { return 3 }
        let phase = time * 3.4 + Double(index) * 0.85
        let normalized = (sin(phase) + 1) / 2
        return 3 + normalized * (height - 3)
    }
}
