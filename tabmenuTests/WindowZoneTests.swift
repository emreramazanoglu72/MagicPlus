//
//  WindowZoneTests.swift
//  tabmenuTests
//

import Testing
import CoreGraphics
@testable import tabmenu

@Suite("Window zones")
struct WindowZoneTests {
    /// A screen that is not at the origin, so any zone that ignores `area.origin` fails here.
    private let area = CGRect(x: 100, y: 50, width: 1200, height: 800)

    @Test func leftHalfTakesTheLeftSide() {
        #expect(WindowZone.leftHalf.frame(in: area) == CGRect(x: 100, y: 50, width: 600, height: 800))
    }

    @Test func rightHalfStartsAtTheMidpoint() {
        #expect(WindowZone.rightHalf.frame(in: area) == CGRect(x: 700, y: 50, width: 600, height: 800))
    }

    /// Zone geometry is in Accessibility space, where y grows downwards — so "top" must sit
    /// at the smaller y, not the larger one.
    @Test func topHalfSitsAtTheSmallerY() {
        #expect(WindowZone.topHalf.frame(in: area) == CGRect(x: 100, y: 50, width: 1200, height: 400))
    }

    @Test func bottomHalfSitsBelowTheMidpoint() {
        #expect(WindowZone.bottomHalf.frame(in: area) == CGRect(x: 100, y: 450, width: 1200, height: 400))
    }

    @Test func maximizeFillsTheWholeArea() {
        #expect(WindowZone.maximize.frame(in: area) == area)
    }

    @Test(arguments: [
        (WindowZone.topLeftQuarter, CGRect(x: 100, y: 50, width: 600, height: 400)),
        (WindowZone.topRightQuarter, CGRect(x: 700, y: 50, width: 600, height: 400)),
        (WindowZone.bottomLeftQuarter, CGRect(x: 100, y: 450, width: 600, height: 400)),
        (WindowZone.bottomRightQuarter, CGRect(x: 700, y: 450, width: 600, height: 400))
    ])
    func quartersCoverTheirCorner(zone: WindowZone, expected: CGRect) {
        #expect(zone.frame(in: area) == expected)
    }

    @Test func thirdsTileWithoutGapsOrOverlap() {
        let left = WindowZone.leftThird.frame(in: area)
        let centre = WindowZone.centerThird.frame(in: area)
        let right = WindowZone.rightThird.frame(in: area)

        #expect(left.maxX == centre.minX)
        #expect(centre.maxX == right.minX)
        #expect(left.minX == area.minX)
        #expect(right.maxX == area.maxX)
    }

    @Test func twoThirdsIsTwiceAThird() {
        let third = WindowZone.leftThird.frame(in: area)
        let twoThirds = WindowZone.leftTwoThirds.frame(in: area)
        #expect(twoThirds.width == third.width * 2)
        #expect(twoThirds.minX == area.minX)
    }

    @Test func rightTwoThirdsEndsAtTheRightEdge() {
        #expect(WindowZone.rightTwoThirds.frame(in: area).maxX == area.maxX)
    }

    @Test func centreIsInsetOnEverySide() {
        let frame = WindowZone.center.frame(in: area)
        #expect(frame.minX > area.minX)
        #expect(frame.maxX < area.maxX)
        #expect(frame.minY > area.minY)
        #expect(frame.maxY < area.maxY)
    }

    @Test func everyZoneStaysWithinTheScreen() {
        for zone in WindowZone.allCases {
            let frame = zone.frame(in: area)
            #expect(area.contains(frame), "\(zone.rawValue) escaped the screen area")
        }
    }
}

@Suite("Frame comparison")
struct FrameComparisonTests {
    @Test func smallDifferencesAreTreatedAsEqual() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 3, y: -2, width: 102, height: 98)
        #expect(a.isApproximatelyEqual(to: b))
    }

    @Test func largeDifferencesAreNot() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 20, y: 0, width: 100, height: 100)
        #expect(!a.isApproximatelyEqual(to: b))
    }

    @Test func toleranceIsConfigurable() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 10, y: 0, width: 100, height: 100)
        #expect(a.isApproximatelyEqual(to: b, tolerance: 12))
        #expect(!a.isApproximatelyEqual(to: b, tolerance: 4))
    }
}
