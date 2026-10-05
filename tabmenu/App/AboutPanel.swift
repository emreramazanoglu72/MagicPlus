//
//  AboutPanel.swift
//  MagicPlus
//

import AppKit

/// The standard About panel, filled in from the bundle.
///
/// An app that never says which version it is running cannot have its bug reports answered, and
/// with updates arriving on their own the version is the one fact worth being able to check. There
/// is no window of our own here on purpose: AppKit already draws this panel, reads the name,
/// version, build and copyright straight from the bundle, and gets the details right. The only
/// thing worth adding is the credit text.
@MainActor
enum AboutPanel {
    static func show() {
        // A menu bar app is never the frontmost application, and a panel behind every other window
        // is the same as no panel at all.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static let website = URL(string: "https://magicplus.emreramazanoglu.com.tr")!

    /// Panel credits: what the app is, where it comes from, and whether it looks after itself.
    private static var credits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6

        let text = NSMutableAttributedString(
            string: String(
                localized: "Windows, clipboard, downloads and what your Mac is doing — from one menu bar item.\n",
                comment: "About panel: one-line description of the app"
            ),
            attributes: [
                .font: body,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )

        text.append(NSAttributedString(
            string: website.host ?? website.absoluteString,
            attributes: [
                .font: body,
                .link: website,
                .paragraphStyle: paragraph
            ]
        ))

        // Said out loud because an app that reaches the network on a schedule should admit it
        // where the version is read, not only in a settings pane nobody opens.
        if UpdaterService.isConfigured {
            text.append(NSAttributedString(
                string: String(
                    localized: "\nChecks for updates once a day.",
                    comment: "About panel: automatic update checks are on"
                ),
                attributes: [
                    .font: body,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph
                ]
            ))
        }

        return text
    }
}
