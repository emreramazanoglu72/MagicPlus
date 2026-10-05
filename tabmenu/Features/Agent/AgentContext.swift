//
//  AgentContext.swift
//  MagicPlus
//

import AppKit
import Foundation

/// What the assistant is told about the moment, without being asked.
///
/// Every one of these is something a tool could go and find out, and every one of those trips is a
/// paid round of the loop: the model calls `system_status`, waits, reads the answer, then finally
/// says something. A measured two-round exchange was about twenty-two hundred input tokens, and a
/// great deal of that was spent learning things this app already knew.
///
/// So they are handed over at the start instead. Roughly forty tokens, and questions like "what am
/// I in?" or "what is this playing?" are answered in one round rather than two.
///
/// What is deliberately *not* here: the clipboard. Searching it is a tool somebody invokes, and what
/// leaves the machine then is what they asked for. Putting the last thing copied into the system
/// prompt would send it with *every* message, whether it was wanted or not — and the clipboard is
/// exactly where passwords are.
nonisolated struct AgentContext: Equatable, Sendable {
    var now: Date?
    var frontmostApplication = ""
    var frontmostWindowTitle = ""
    var nowPlaying = ""
    var battery = ""

    var isEmpty: Bool { describe().isEmpty }

    /// The context as the model reads it, or empty when there is nothing worth saying.
    ///
    /// Written as plain lines rather than JSON: it is read, not parsed, and every brace is a token
    /// spent on punctuation.
    func describe() -> String {
        var lines: [String] = []

        if let now {
            // Models have no clock, and "today" is in a surprising number of questions.
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            lines.append("Now: \(formatter.string(from: now))")
        }
        if !frontmostApplication.isEmpty {
            let window = frontmostWindowTitle.isEmpty ? "" : " — \(frontmostWindowTitle)"
            lines.append("In front: \(frontmostApplication)\(window)")
        }
        if !nowPlaying.isEmpty { lines.append("Playing: \(nowPlaying)") }
        if !battery.isEmpty { lines.append("Battery: \(battery)") }

        return lines.joined(separator: "\n")
    }
}

/// Gathers the context from whatever the app already has running.
///
/// Nothing here is allowed to be expensive. The dock polls the front application and playback on its
/// own timer, so those are read from what it last saw rather than asked for again — asking would
/// mean an `osascript` subprocess on the way to every message.
@MainActor
enum AgentContextReader {
    static func read(dock: DockModel?, isDockRunning: Bool) -> AgentContext {
        var context = AgentContext()
        context.now = Date()

        if isDockRunning, let dock {
            context.frontmostApplication = dock.frontmostName
            context.frontmostWindowTitle = dock.frontmostWindowTitle
            if let playing = dock.nowPlaying {
                context.nowPlaying = playing.artist.isEmpty
                    ? playing.title
                    : "\(playing.title) — \(playing.artist)"
            }
        } else if let front = NSWorkspace.shared.frontmostApplication,
                  front.bundleIdentifier != Bundle.main.bundleIdentifier {
            // Without the dock there is nothing polling, and the application in front is the one
            // thing cheap enough to ask for directly.
            context.frontmostApplication = front.localizedName ?? ""
        }

        let battery = SystemStatus.battery()
        if battery.isPresent {
            context.battery = "\(battery.percentage)%\(battery.isCharging ? ", charging" : "")"
        }
        return context
    }
}
