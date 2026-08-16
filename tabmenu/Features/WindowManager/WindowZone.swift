//
//  WindowZone.swift
//  tabmenu
//

import CoreGraphics
import Foundation

/// A target rectangle on screen, expressed as a fraction of the usable screen area.
/// All geometry is in Accessibility space: origin at the top-left of the primary display.
enum WindowZone: String, CaseIterable, Codable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case topThird, bottomThird, topTwoThirds, bottomTwoThirds
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case maximize, center

    var id: String { rawValue }

    /// Shown when picking a zone for a window rule.
    var title: String {
        switch self {
        case .leftHalf: String(localized: "Left half", comment: "Window zone")
        case .rightHalf: String(localized: "Right half", comment: "Window zone")
        case .topHalf: String(localized: "Top half", comment: "Window zone")
        case .bottomHalf: String(localized: "Bottom half", comment: "Window zone")
        case .leftThird: String(localized: "Left third", comment: "Window zone")
        case .centerThird: String(localized: "Centre third", comment: "Window zone")
        case .rightThird: String(localized: "Right third", comment: "Window zone")
        case .leftTwoThirds: String(localized: "Left two thirds", comment: "Window zone")
        case .rightTwoThirds: String(localized: "Right two thirds", comment: "Window zone")
        case .topThird: String(localized: "Top third", comment: "Window zone")
        case .bottomThird: String(localized: "Bottom third", comment: "Window zone")
        case .topTwoThirds: String(localized: "Top two thirds", comment: "Window zone")
        case .bottomTwoThirds: String(localized: "Bottom two thirds", comment: "Window zone")
        case .topLeftQuarter: String(localized: "Top left quarter", comment: "Window zone")
        case .topRightQuarter: String(localized: "Top right quarter", comment: "Window zone")
        case .bottomLeftQuarter: String(localized: "Bottom left quarter", comment: "Window zone")
        case .bottomRightQuarter: String(localized: "Bottom right quarter", comment: "Window zone")
        case .maximize: String(localized: "Full screen", comment: "Window zone")
        case .center: String(localized: "Centred", comment: "Window zone")
        }
    }

    func frame(in area: CGRect) -> CGRect {
        let width = area.width
        let height = area.height
        let x = area.minX
        let y = area.minY

        switch self {
        case .leftHalf:
            return CGRect(x: x, y: y, width: width / 2, height: height)
        case .rightHalf:
            return CGRect(x: x + width / 2, y: y, width: width / 2, height: height)
        case .topHalf:
            return CGRect(x: x, y: y, width: width, height: height / 2)
        case .bottomHalf:
            return CGRect(x: x, y: y + height / 2, width: width, height: height / 2)

        case .leftThird:
            return CGRect(x: x, y: y, width: width / 3, height: height)
        case .centerThird:
            return CGRect(x: x + width / 3, y: y, width: width / 3, height: height)
        case .rightThird:
            return CGRect(x: x + width * 2 / 3, y: y, width: width / 3, height: height)
        case .leftTwoThirds:
            return CGRect(x: x, y: y, width: width * 2 / 3, height: height)
        case .rightTwoThirds:
            return CGRect(x: x + width / 3, y: y, width: width * 2 / 3, height: height)

        case .topThird:
            return CGRect(x: x, y: y, width: width, height: height / 3)
        case .bottomThird:
            return CGRect(x: x, y: y + height * 2 / 3, width: width, height: height / 3)
        case .topTwoThirds:
            return CGRect(x: x, y: y, width: width, height: height * 2 / 3)
        case .bottomTwoThirds:
            return CGRect(x: x, y: y + height / 3, width: width, height: height * 2 / 3)

        case .topLeftQuarter:
            return CGRect(x: x, y: y, width: width / 2, height: height / 2)
        case .topRightQuarter:
            return CGRect(x: x + width / 2, y: y, width: width / 2, height: height / 2)
        case .bottomLeftQuarter:
            return CGRect(x: x, y: y + height / 2, width: width / 2, height: height / 2)
        case .bottomRightQuarter:
            return CGRect(x: x + width / 2, y: y + height / 2, width: width / 2, height: height / 2)

        case .maximize:
            return area
        case .center:
            return CGRect(
                x: x + width * 0.2,
                y: y + height * 0.15,
                width: width * 0.6,
                height: height * 0.7
            )
        }
    }
}

extension CGRect {
    /// Windows are never placed pixel-perfectly, so zone matching needs a tolerance.
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat = 6) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
