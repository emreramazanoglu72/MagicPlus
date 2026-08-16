//
//  ClipboardAndHistoryTests.swift
//  tabmenuTests
//

import Testing
import CoreGraphics
import Foundation
@testable import tabmenu

@Suite("Clipboard entries")
struct ClipboardItemTests {
    @Test func identicalTextSharesAFingerprint() {
        let first = ClipboardItem(content: .text("hello"))
        let second = ClipboardItem(content: .text("hello"))
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.id != second.id)
    }

    @Test func differentTextDoesNot() {
        #expect(ClipboardItem(content: .text("a")).fingerprint != ClipboardItem(content: .text("b")).fingerprint)
    }

    /// The same file list copied twice must collapse into one entry, whatever the order it
    /// was captured in.
    @Test func fileListsFingerprintByPath() {
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        let first = ClipboardItem(content: .fileURLs(urls))
        let second = ClipboardItem(content: .fileURLs(urls))
        #expect(first.fingerprint == second.fingerprint)
    }

    @Test func textAndFileFingerprintsNeverCollide() {
        let text = ClipboardItem(content: .text("/tmp/a.txt"))
        let file = ClipboardItem(content: .fileURLs([URL(fileURLWithPath: "/tmp/a.txt")]))
        #expect(text.fingerprint != file.fingerprint)
    }

    @Test func titleCollapsesNewlinesSoRowsStayOneLine() {
        let item = ClipboardItem(content: .text("first\nsecond"))
        #expect(!item.title.contains("\n"))
    }

    @Test func plainTextIsOnlyExposedForText() {
        #expect(ClipboardItem(content: .text("x")).plainText == "x")
        #expect(ClipboardItem(content: .image(fileName: "a.png", pixelSize: .zero)).plainText == nil)
    }

    @Test func searchTextIncludesSourceApplication() {
        let item = ClipboardItem(content: .text("payload"), sourceAppName: "Safari")
        #expect(item.searchText.contains("Safari"))
        #expect(item.searchText.contains("payload"))
    }

    @Test func singleFileTitleIsItsName() {
        let item = ClipboardItem(content: .fileURLs([URL(fileURLWithPath: "/tmp/report.pdf")]))
        #expect(item.title == "report.pdf")
    }
}

@Suite("Metric history")
struct MetricHistoryTests {
    @Test func keepsOnlyTheMostRecentSamples() {
        var history = MetricHistory(capacity: 3)
        for value in [1.0, 2.0, 3.0, 4.0] { history.append(value) }
        #expect(history.samples == [2.0, 3.0, 4.0])
    }

    @Test func normalisesAgainstItsOwnPeak() {
        var history = MetricHistory()
        history.append(0)
        history.append(50)
        history.append(100)
        #expect(history.normalized() == [0, 0.5, 1])
    }

    /// An all-zero series must not divide by zero, or the sparkline renders as NaN.
    @Test func handlesASilentSeries() {
        var history = MetricHistory()
        for _ in 0..<3 { history.append(0) }
        #expect(history.normalized().allSatisfy { $0 == 0 })
    }

    @Test func startsEmpty() {
        #expect(MetricHistory().samples.isEmpty)
        #expect(MetricHistory().normalized().isEmpty)
    }
}
