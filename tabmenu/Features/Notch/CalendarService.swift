//
//  CalendarService.swift
//  tabmenu
//

import AppKit
import EventKit
import os
import Observation

struct AgendaEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let meetingURL: URL?
    let calendarColor: Color

    var isInProgress: Bool {
        let now = Date()
        return startDate <= now && endDate > now
    }

    func minutesUntilStart(from now: Date = Date()) -> Int {
        Int(startDate.timeIntervalSince(now) / 60)
    }

    /// Short label for the notch: "now", "in 5m", "14:30".
    func countdownLabel(from now: Date = Date()) -> String {
        if isInProgress {
            return String(localized: "now", comment: "A meeting that has already started")
        }
        let minutes = minutesUntilStart(from: now)
        guard minutes < 60 else { return startDate.formatted(date: .omitted, time: .shortened) }
        return String(localized: "in \(max(minutes, 0))m", comment: "Minutes until a meeting starts")
    }
}

import SwiftUI

/// Reads the next few calendar events and finds the link needed to join them.
@Observable
@MainActor
final class CalendarService {
    private(set) var events: [AgendaEvent] = []
    private(set) var isAuthorized = false

    @ObservationIgnored private let logger = Logger(subsystem: "com.tabmenu", category: "Calendar")
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var refreshTimer: Timer?

    /// How far ahead the notch looks.
    private static let lookaheadHours = 12
    /// An event this close counts as a live activity worth showing while collapsed.
    private static let imminentMinutes = 15

    init() {
        updateAuthorization()
    }

    /// The event worth surfacing in the collapsed island.
    var imminentEvent: AgendaEvent? {
        events.first {
            $0.isInProgress || (0...Self.imminentMinutes).contains($0.minutesUntilStart())
        }
    }

    var nextEvent: AgendaEvent? { events.first }

    // MARK: - Lifecycle

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        // Calendars change rarely; a slow tick keeps the countdown honest without cost.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func requestAccess() {
        // The panel never takes focus, and macOS will not put a permission prompt in front of
        // a background app — so the app is brought forward before asking.
        NSApp.activate(ignoringOtherApps: true)
        logger.notice("requesting calendar access")

        store.requestFullAccessToEvents { granted, error in
            Task { @MainActor [weak self] in
                self?.logger.notice(
                    "calendar access granted=\(granted) error=\(error?.localizedDescription ?? "none", privacy: .public)"
                )
                self?.updateAuthorization()
                self?.refresh()
            }
        }
    }

    // MARK: - Loading

    func refresh() {
        updateAuthorization()
        guard isAuthorized else {
            events = []
            return
        }

        let now = Date()
        guard let end = Calendar.current.date(byAdding: .hour, value: Self.lookaheadHours, to: now) else { return }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: end, calendars: nil)

        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map(Self.makeEvent)
    }

    private func updateAuthorization() {
        isAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    private static func makeEvent(_ event: EKEvent) -> AgendaEvent {
        AgendaEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled event",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location,
            meetingURL: MeetingLink.find(in: [event.notes, event.location, event.url?.absoluteString]),
            calendarColor: event.calendar.map { Color(nsColor: NSColor(cgColor: $0.cgColor) ?? .systemBlue) } ?? .blue
        )
    }

    func join(_ event: AgendaEvent) {
        guard let url = event.meetingURL else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Pulls a video-call link out of the free-form fields organisers put them in.
enum MeetingLink {
    private static let hosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "around.co", "gather.town"
    ]

    static func find(in fields: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }

        for field in fields.compactMap({ $0 }) where !field.isEmpty {
            let range = NSRange(field.startIndex..., in: field)
            for match in detector.matches(in: field, range: range) {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                // Exact host or true subdomain only — a substring check would let
                // "zoom.us.attacker.com" impersonate "zoom.us".
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}
