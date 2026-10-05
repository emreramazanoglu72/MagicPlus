//
//  IssueReportTests.swift
//  tabmenuTests
//

import Foundation
import Testing
@testable import tabmenu

@MainActor
@Suite("Issue report")
struct IssueReportTests {
    private func makePreferences(suite: String = "issue.report.tests") -> Preferences {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return Preferences(defaults: defaults)
    }

    /// The three facts a report is useless without.
    @Test func namesTheBuildTheMachineAndTheModules() {
        let report = IssueReport.text(
            preferences: makePreferences(),
            accessibilityGranted: true,
            screenRecordingGranted: false,
            logLines: []
        )

        #expect(report.contains("MagicPlus \(IssueReport.version)"))
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #expect(report.contains("macOS \(version.majorVersion).\(version.minorVersion)"))
        #expect(!report.contains("Sürüm"), "the system version must not be localised in a report")
        #expect(report.contains("Modules on:"))
        #expect(report.contains("Modules off:"))
        // A module that is on has to be named, or "which modules" is unanswered.
        #expect(report.contains(AppModule.windows.rawValue))
    }

    @Test func saysWhichPermissionsAreMissing() {
        let granted = IssueReport.text(
            preferences: makePreferences(),
            accessibilityGranted: true,
            screenRecordingGranted: true,
            logLines: []
        )
        let denied = IssueReport.text(
            preferences: makePreferences(),
            accessibilityGranted: false,
            screenRecordingGranted: false,
            logLines: []
        )

        #expect(granted.contains("Accessibility: granted"))
        #expect(denied.contains("Accessibility: not granted"))
        #expect(denied.contains("Screen Recording: not granted"))
    }

    /// A body a mail client truncates on its own loses its tail silently. This one stops early and
    /// says it stopped.
    @Test func staysWithinWhatAMailClientWillCarry() {
        let noisy = (1...400).map { "12:00:0\($0 % 10) Downloads something went wrong number \($0)" }
        let report = IssueReport.text(
            preferences: makePreferences(),
            accessibilityGranted: true,
            screenRecordingGranted: true,
            logLines: noisy
        )

        #expect(report.count < 1900, "report grew to \(report.count) characters")
        #expect(report.contains("…"), "a truncated report has to admit it")
    }

    /// Switching a module off has to show up in the report, or a report from someone running two
    /// modules reads like a report from someone running fifteen.
    @Test func followsWhatIsActuallySwitchedOn() {
        let preferences = makePreferences()
        preferences.setEnabled(false, for: .downloads)
        preferences.setEnabled(false, for: .notch)

        let report = IssueReport.text(
            preferences: preferences,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            logLines: []
        )

        let onLine = report.split(separator: "\n").first { $0.hasPrefix("Modules on:") } ?? ""
        let offLine = report.split(separator: "\n").first { $0.hasPrefix("Modules off:") } ?? ""
        #expect(!onLine.contains(AppModule.downloads.rawValue))
        #expect(offLine.contains(AppModule.downloads.rawValue))
        #expect(offLine.contains(AppModule.notch.rawValue))
    }
}

@MainActor
@Suite("Hardware safety")
struct HardwareSafetyTests {
    /// The charge limit writes to the battery controller, and it has only ever been exercised on
    /// the machines we happen to own. It must therefore be something the user turns on, never
    /// something they discover already running — on top of which the privileged helper has to be
    /// installed before a single write happens.
    @Test func theChargeLimitIsOffUntilItIsAskedFor() {
        let suite = "hardware.safety.tests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: defaults)

        #expect(preferences.isChargeLimitEnabled == false)
        // The pane may be visible — readings are harmless — but the write must not be armed.
        #expect(preferences.isEnabled(.hardware))
        #expect(preferences.chargeLimitPercentage == 80, "a limit that defaults to 100 is not a limit")
    }
}
