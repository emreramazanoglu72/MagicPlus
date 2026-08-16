//
//  KeepAwakeDuration.swift
//  tabmenu
//

import Foundation

/// How long a keep-awake session runs before it switches itself off.
enum KeepAwakeDuration: String, CaseIterable, Identifiable, Codable {
    case indefinitely
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours

    var id: String { rawValue }

    /// `nil` runs until the toggle is switched off again.
    var seconds: TimeInterval? {
        switch self {
        case .indefinitely: nil
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .fourHours: 4 * 60 * 60
        }
    }

    var title: String {
        switch self {
        case .indefinitely:
            String(localized: "Until turned off", comment: "Keep-awake session with no timer")
        case .fifteenMinutes, .thirtyMinutes, .oneHour, .twoHours, .fourHours:
            Self.durationFormatter.string(from: seconds ?? 0) ?? rawValue
        }
    }

    /// Compact form for the chips in the popover card. Digits and unit letters are stable
    /// across locales, so these stay verbatim.
    var shortTitle: String {
        switch self {
        case .indefinitely: "∞"
        case .fifteenMinutes: "15m"
        case .thirtyMinutes: "30m"
        case .oneHour: "1h"
        case .twoHours: "2h"
        case .fourHours: "4h"
        }
    }

    /// Spells out durations in the user's language: "15 minutes", "15 dakika".
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()
}
