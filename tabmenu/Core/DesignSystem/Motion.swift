//
//  Motion.swift
//  tabmenu
//

import SwiftUI

/// Motion vocabulary for the app. Everything animated goes through these curves so the
/// whole surface moves with one personality.
enum Motion {
    /// Selection changes, hovers, taps.
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.76)
    /// Layout and morphing glass.
    static let fluid = Animation.spring(response: 0.48, dampingFraction: 0.82)
    /// Metric values easing towards a new reading.
    static let metric = Animation.spring(response: 0.65, dampingFraction: 0.9)
    /// Panel and tab content entering or leaving.
    static let transition = Animation.spring(response: 0.42, dampingFraction: 0.88)
    /// The notch island growing and shrinking: a touch of overshoot gives it its bounce.
    static let island = Animation.spring(response: 0.38, dampingFraction: 0.72)
}

extension View {
    /// Animates a value change, honouring the system's Reduce Motion setting.
    func motion(_ animation: Animation, value: some Equatable) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Runs a mutation inside the app's motion curves unless Reduce Motion is on.
@MainActor
func withMotion(_ animation: Animation, reduceMotion: Bool, _ body: () -> Void) {
    if reduceMotion {
        body()
    } else {
        withAnimation(animation, body)
    }
}
