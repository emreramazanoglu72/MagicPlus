//
//  NotchShape.swift
//  tabmenu
//

import SwiftUI

/// The island's silhouette: a rounded body whose top corners flare outwards into concave
/// shoulders, so the panel reads as the menu bar bending around the hardware notch rather
/// than a rectangle sitting on top of it.
///
/// The shoulders are drawn inside the given rect — the body is inset by `shoulderRadius` on
/// each side — so nothing is clipped away.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulderRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulderRadius) }
        set {
            bottomRadius = newValue.first
            shoulderRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = max(0, min(shoulderRadius, rect.width / 2))
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let corner = max(0, min(bottomRadius, (right - left) / 2, rect.height))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Left shoulder: curves down and inwards, away from the menu bar.
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.minY + shoulder),
            control: CGPoint(x: left, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: left, y: rect.maxY - corner))
        path.addQuadCurve(
            to: CGPoint(x: left + corner, y: rect.maxY),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right - corner, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.maxY - corner),
            control: CGPoint(x: right, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))

        // Right shoulder, mirrored.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: right, y: rect.minY)
        )
        path.closeSubpath()

        return path
    }
}
