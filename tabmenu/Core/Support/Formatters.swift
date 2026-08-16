//
//  Formatters.swift
//  tabmenu
//

import Foundation

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    private static let compactByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        compactByteFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond))) + "/s"
    }

    /// Percent sign placement differs by locale, so the number formatter decides it.
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// - Parameter fraction: A ratio in the `0...1` range.
    static func percent(_ fraction: Double) -> String {
        percentFormatter.string(from: NSNumber(value: fraction))
            ?? "\(Int((fraction * 100).rounded()))%"
    }

    /// `1:04:09` or `12:30` for a remaining interval, rounded up so a live countdown never
    /// shows a value the user has not reached yet.
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// Abbreviated age of an entry, e.g. "now", "5m ago". Anything under a minute reads as
    /// "now" rather than "0 seconds ago".
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else {
            return String(localized: "now", comment: "Age of a just-captured clipboard entry")
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}
