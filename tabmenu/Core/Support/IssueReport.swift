//
//  IssueReport.swift
//  MagicPlus
//

import AppKit
import OSLog

/// A bug report the user only has to describe, not assemble.
///
/// The app sends nothing anywhere on its own — there is no analytics in it and there is not going
/// to be — and the cost of that choice is that a failure nobody can describe is a failure that
/// will never be fixed. So the app writes the report itself: which build, which macOS, which
/// machine, which modules were switched on, what was granted, and what the log recorded. The user
/// adds the one thing only they know, which is what they were doing.
///
/// Everything here is read at the moment the user asks for it and goes into an email they can read
/// before sending. Nothing is collected in the background, and nothing leaves without them
/// pressing send.
@MainActor
enum IssueReport {
    static let address = "emreramazanoglu@yahoo.com"

    /// Mail clients handle long `mailto:` bodies unevenly, and a report that silently loses its
    /// tail is worse than a shorter one that does not. The log section is trimmed to fit.
    private static let bodyLimit = 1800

    static func compose(
        preferences: Preferences,
        accessibility: AccessibilityPermission,
        screenRecording: ScreenRecordingPermission
    ) {
        let body = text(
            preferences: preferences,
            accessibilityGranted: accessibility.isTrusted,
            screenRecordingGranted: screenRecording.isGranted,
            logLines: recentErrors()
        )

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]

        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    static var subject: String {
        "MagicPlus \(version) — \(String(localized: "issue report", comment: "Email subject suffix for a bug report"))"
    }

    /// The report itself. Separated from sending it so its shape can be tested.
    static func text(
        preferences: Preferences,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        logLines: [String]
    ) -> String {
        let on = AppModule.allCases.filter { preferences.isEnabled($0) }.map(\.rawValue)
        let off = AppModule.allCases.filter { !preferences.isEnabled($0) }.map(\.rawValue)

        var report = """
        \(String(localized: "What were you doing when it went wrong?", comment: "Bug report: the one thing only the user knows"))


        ---
        MagicPlus \(version)
        \(systemVersion)
        \(hardwareModel) · \(architecture)
        Language: \(Locale.current.identifier)

        Modules on:  \(on.isEmpty ? "—" : on.joined(separator: ", "))
        Modules off: \(off.isEmpty ? "—" : off.joined(separator: ", "))

        Accessibility: \(accessibilityGranted ? "granted" : "not granted")
        Screen Recording: \(screenRecordingGranted ? "granted" : "not granted")
        """

        if !logLines.isEmpty {
            report += "\n\nRecent errors:\n"
            for line in logLines {
                // Stop before the body grows past what a mail client will carry intact.
                guard report.count + line.count + 3 < bodyLimit else {
                    report += "  …\n"
                    break
                }
                report += "  \(line)\n"
            }
        }

        return report
    }

    // MARK: - Facts about this build and machine

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Built rather than borrowed: `operatingSystemVersionString` is localised, and a report that
    /// says "Sürüm 26.5.1 (Geliştirme 25F80)" to one reader and "Version …" to another is a report
    /// that cannot be searched or compared.
    private static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctlString("kern.osversion") ?? "?"
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(build))"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    private static var hardwareModel: String {
        sysctlString("hw.model") ?? "unknown Mac"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// Errors this run of the app recorded.
    ///
    /// `currentProcessIdentifier` is the only scope available without the log-reading entitlement,
    /// so this covers the session the user is reporting from and not the one before it. That is the
    /// session they are describing, which is the one that matters.
    private static func recentErrors(limit: Int = 12) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }

        let since = store.position(timeIntervalSinceLatestBoot: 1)
        guard let entries = try? store.getEntries(
            with: [],
            at: since,
            matching: NSPredicate(format: "subsystem == %@", "com.tabmenu")
        ) else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        return entries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.level == .error || $0.level == .fault }
            .suffix(limit)
            .map { "\(formatter.string(from: $0.date)) \($0.category) \($0.composedMessage)" }
    }
}
