//
//  NotchActivity.swift
//  tabmenu
//

import SwiftUI

/// A transient thing worth showing in the island. Each one appears, holds for its own
/// duration, then the island collapses back to the bare notch.
enum NotchActivity: Equatable {
    case nowPlaying(NowPlaying)
    case volume(Double)
    case meeting(AgendaEvent)
    case filesAdded(Int)
    case screenshot(URL)
    case download(name: String)
    case micStatus(muted: Bool)
    case textCaptured(Int)
    case lowBattery(Int)
    case diskFull(freeBytes: Int64)
    case windowsRescued(Int)
    case sleepDespiteKeepAwake
    case power(isCharging: Bool, percentage: Int)

    /// Higher wins when two things happen at once: a meeting about to start matters more
    /// than a track change.
    var priority: Int {
        switch self {
        case .meeting: 40
        case .volume: 30
        case .power: 20
        case .filesAdded: 15
        case .screenshot: 25
        case .download: 22
        case .micStatus: 45
        case .textCaptured: 28
        case .lowBattery: 38
        case .diskFull: 36
        case .windowsRescued: 26
        case .sleepDespiteKeepAwake: 39
        case .nowPlaying: 10
        }
    }

    /// How long it stays before the island collapses. Volume repeats as the user holds the
    /// key, so it lingers only briefly; a meeting reminder is worth reading.
    var duration: Duration {
        switch self {
        case .volume: .milliseconds(1400)
        case .filesAdded: .seconds(2)
        case .screenshot: .seconds(3)
        case .download: .seconds(3)
        case .micStatus: .milliseconds(1400)
        case .textCaptured: .milliseconds(2500)
        case .lowBattery: .seconds(5)
        case .diskFull: .seconds(5)
        case .windowsRescued: .milliseconds(2500)
        case .sleepDespiteKeepAwake: .seconds(5)
        case .nowPlaying, .power: .seconds(3)
        case .meeting: .seconds(5)
        }
    }

    /// Width of the content on each side of the physical notch.
    var sideWidth: CGFloat {
        switch self {
        case .volume: 78
        case .power: 66
        case .filesAdded: 74
        case .screenshot: 96
        case .download: 104
        case .micStatus: 70
        case .textCaptured: 92
        case .lowBattery: 84
        case .diskFull: 96
        case .windowsRescued: 92
        case .sleepDespiteKeepAwake: 108
        case .nowPlaying, .meeting: 96
        }
    }

    var tint: Color {
        switch self {
        case .nowPlaying: Accent.clipboard
        case .volume: .cyan
        case .meeting(let event): event.calendarColor
        case .filesAdded: Accent.windows
        case .screenshot: Accent.clipboard
        case .download: .green
        case .micStatus(let muted): muted ? .red : .orange
        case .textCaptured: Accent.clipboard
        case .lowBattery: .red
        case .diskFull: .orange
        case .windowsRescued: Accent.windows
        case .sleepDespiteKeepAwake: .yellow
        case .power(let isCharging, _): isCharging ? .green : .orange
        }
    }

    /// Two activities of the same kind replace one another instead of queueing, so holding
    /// the volume key does not stack up a backlog.
    var kindIdentifier: String {
        switch self {
        case .nowPlaying: "nowPlaying"
        case .volume: "volume"
        case .meeting: "meeting"
        case .filesAdded: "filesAdded"
        case .screenshot: "screenshot"
        case .download: "download"
        case .micStatus: "micStatus"
        case .textCaptured: "textCaptured"
        case .lowBattery: "lowBattery"
        case .diskFull: "diskFull"
        case .windowsRescued: "windowsRescued"
        case .sleepDespiteKeepAwake: "sleepDespiteKeepAwake"
        case .power: "power"
        }
    }
}
