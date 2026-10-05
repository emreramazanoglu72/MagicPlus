//
//  MenuBarManagerTests.swift
//  tabmenuTests
//

import Testing
import CoreGraphics
import SwiftUI
@testable import tabmenu

@Suite("Menu bar sections")
struct MenuBarSectionTests {
    @Test func itemsRightOfTheDividerStayVisible() {
        let section = MenuBarLayout.section(
            itemMinX: 900,
            hiddenDividerMinX: 800,
            alwaysHiddenDividerMinX: nil
        )
        #expect(section == .visible)
    }

    @Test func itemsLeftOfTheDividerAreHidden() {
        let section = MenuBarLayout.section(
            itemMinX: 700,
            hiddenDividerMinX: 800,
            alwaysHiddenDividerMinX: nil
        )
        #expect(section == .hidden)
    }

    /// An item sitting exactly on the boundary is still on the visible side of it, which is
    /// what the menu bar draws.
    @Test func theBoundaryItselfCountsAsVisible() {
        let section = MenuBarLayout.section(
            itemMinX: 800,
            hiddenDividerMinX: 800,
            alwaysHiddenDividerMinX: nil
        )
        #expect(section == .visible)
    }

    @Test func everythingIsVisibleUntilTheDividersExist() {
        let section = MenuBarLayout.section(
            itemMinX: 10,
            hiddenDividerMinX: nil,
            alwaysHiddenDividerMinX: nil
        )
        #expect(section == .visible)
    }

    @Test func theFarSideBelongsToTheAlwaysHiddenSection() {
        let section = MenuBarLayout.section(
            itemMinX: 300,
            hiddenDividerMinX: 800,
            alwaysHiddenDividerMinX: 500
        )
        #expect(section == .alwaysHidden)
    }

    @Test func itemsBetweenTheDividersAreMerelyHidden() {
        let section = MenuBarLayout.section(
            itemMinX: 650,
            hiddenDividerMinX: 800,
            alwaysHiddenDividerMinX: 500
        )
        #expect(section == .hidden)
    }

    /// Dividers can be dragged past one another. Clamping the deeper boundary keeps that
    /// from turning the whole bar into the always-hidden section.
    @Test func dividersDraggedOutOfOrderStillResolve() {
        #expect(
            MenuBarLayout.section(itemMinX: 850, hiddenDividerMinX: 800, alwaysHiddenDividerMinX: 900) == .visible
        )
        #expect(
            MenuBarLayout.section(itemMinX: 700, hiddenDividerMinX: 800, alwaysHiddenDividerMinX: 900) == .alwaysHidden
        )
    }

    @Test func onlyTheCollapsibleSectionsCanFoldAway() {
        #expect(!MenuBarSection.visible.isCollapsible)
        #expect(MenuBarSection.hidden.isCollapsible)
        #expect(MenuBarSection.alwaysHidden.isCollapsible)
    }
}

@Suite("Menu bar items")
struct MenuBarItemTests {
    private func item(owner: String, title: String, windowID: CGWindowID = 1, minX: CGFloat = 0) -> MenuBarItem {
        MenuBarItem(
            windowID: windowID,
            processIdentifier: 42,
            ownerName: owner,
            title: title,
            frame: CGRect(x: minX, y: 0, width: 30, height: 24),
            isOnScreen: true
        )
    }

    /// Window IDs are handed out afresh every launch; cached artwork has to survive that.
    @Test func theKeySurvivesANewWindowID() {
        let first = item(owner: "Dropbox", title: "Dropbox", windowID: 11)
        let second = item(owner: "Dropbox", title: "Dropbox", windowID: 99)
        #expect(first.key == second.key)
        #expect(first.id != second.id)
    }

    @Test func differentItemsOfOneAppKeepDifferentKeys() {
        #expect(item(owner: "Control Center", title: "WiFi").key != item(owner: "Control Center", title: "Clock").key)
    }

    @Test func theClickLandsInTheMiddleOfTheItem() {
        let item = item(owner: "Slack", title: "Slack", minX: 100)
        #expect(item.center == CGPoint(x: 115, y: 12))
    }

    @Test func searchTextCoversBothNames() {
        let item = item(owner: "Control Center", title: "BentoBox")
        #expect(item.searchText.contains("Control Center"))
        #expect(item.searchText.contains("BentoBox"))
    }
}

@Suite("Menu bar item names")
struct MenuBarItemNamingTests {
    /// The module names are translated, so the test asserts that the internal name is gone
    /// rather than pinning the result to one language.
    @Test func systemModulesGetTheirRealName() {
        let controlCentre = MenuBarItemNaming.displayName(owner: "Control Center", title: "BentoBox")
        #expect(controlCentre != "BentoBox")
        #expect(!controlCentre.isEmpty)

        let nowPlaying = MenuBarItemNaming.displayName(owner: "Control Center", title: "NowPlaying")
        #expect(nowPlaying != "NowPlaying")
    }

    @Test func anUntitledItemFallsBackToItsApp() {
        #expect(MenuBarItemNaming.displayName(owner: "Dropbox", title: "") == "Dropbox")
        #expect(MenuBarItemNaming.displayName(owner: "Dropbox", title: "   ") == "Dropbox")
    }

    @Test func unknownModulesAreSplitOnTheirCapitals() {
        #expect(MenuBarItemNaming.splitOnCapitals("BatteryStatusItem") == "Battery Status Item")
    }

    @Test func namesThatAreAlreadyReadableAreLeftAlone() {
        #expect(MenuBarItemNaming.splitOnCapitals("Dropbox") == "Dropbox")
        #expect(MenuBarItemNaming.splitOnCapitals("Little Snitch") == "Little Snitch")
    }

    @Test func runsOfCapitalsAreNotBrokenUp() {
        #expect(MenuBarItemNaming.splitOnCapitals("VPNStatus") == "VPNStatus")
    }
}

@Suite("Menu bar spacing")
struct MenuBarSpacingTests {
    @Test func valuesOutsideTheRangeAreClamped() {
        #expect(99.clamped(to: MenuBarSpacing.spacingRange) == MenuBarSpacing.spacingRange.upperBound)
        #expect((-4).clamped(to: MenuBarSpacing.spacingRange) == MenuBarSpacing.spacingRange.lowerBound)
        #expect(16.clamped(to: MenuBarSpacing.spacingRange) == 16)
    }

    @Test func theSystemDefaultsSitInsideTheRanges() {
        #expect(MenuBarSpacing.spacingRange.contains(MenuBarSpacing.defaultSpacing))
        #expect(MenuBarSpacing.paddingRange.contains(MenuBarSpacing.defaultPadding))
    }
}

@Suite("Stored colours")
struct ColorHexTests {
    @Test func hexRoundTrips() {
        #expect(Color(hex: "3478F6").hexString == "3478F6")
        #expect(Color(hex: "#FFFFFF").hexString == "FFFFFF")
        #expect(Color(hex: "000000").hexString == "000000")
    }

    @Test func nonsenseFallsBackInsteadOfTurningBlack() {
        #expect(Color(hex: "not a colour", fallback: .white).hexString == Color.white.hexString)
        #expect(Color(hex: "FFF", fallback: .white).hexString == Color.white.hexString)
    }
}
