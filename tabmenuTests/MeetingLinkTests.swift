//
//  MeetingLinkTests.swift
//  tabmenuTests
//

import Testing
import Foundation
@testable import tabmenu

@Suite("Meeting links")
struct MeetingLinkTests {
    @Test(arguments: [
        "https://us02web.zoom.us/j/123456789",
        "https://meet.google.com/abc-defg-hij",
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
        "https://company.webex.com/meet/someone",
        "https://meet.jit.si/tabmenu-standup"
    ])
    func findsKnownProviders(link: String) {
        #expect(MeetingLink.find(in: ["Join here: \(link)"])?.absoluteString == link)
    }

    @Test func ignoresUnrelatedLinks() {
        let notes = "Agenda doc: https://example.com/notes and https://github.com/some/repo"
        #expect(MeetingLink.find(in: [notes]) == nil)
    }

    @Test func searchesEveryFieldInOrder() {
        let found = MeetingLink.find(in: [nil, "", "no link here", "https://meet.google.com/xyz"])
        #expect(found?.host == "meet.google.com")
    }

    @Test func returnsNilWhenNothingIsProvided() {
        #expect(MeetingLink.find(in: []) == nil)
        #expect(MeetingLink.find(in: [nil, nil]) == nil)
    }

    /// Invites usually bury the link in a wall of boilerplate.
    @Test func findsLinkInsideLongInviteText() {
        let notes = """
        You have been invited to a meeting.

        ---
        Join Zoom Meeting
        https://us02web.zoom.us/j/98765?pwd=abcdef

        Meeting ID: 987 65
        One tap mobile: +1234567890
        """
        #expect(MeetingLink.find(in: [notes])?.host == "us02web.zoom.us")
    }
}
