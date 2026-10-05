//
//  MenuBarSpacing.swift
//  tabmenu
//

import Foundation

/// The gap between menu bar items, and the padding their highlight draws around them.
///
/// Both live in two global preferences that AppKit reads when an app builds its status
/// items, so a change only reaches an app the next time it launches. Nothing here is
/// specific to this app: the values are the ones macOS itself ships with, and `reset()`
/// removes them again rather than writing the defaults back.
enum MenuBarSpacing {
    static let defaultSpacing = 16
    static let defaultPadding = 5
    static let spacingRange = 0...32
    static let paddingRange = 0...16

    private static let spacingKey = "NSStatusItemSpacing" as CFString
    private static let paddingKey = "NSStatusItemSelectionPadding" as CFString

    static var spacing: Int { read(spacingKey) ?? defaultSpacing }
    static var padding: Int { read(paddingKey) ?? defaultPadding }

    static func apply(spacing: Int, padding: Int) {
        write(spacing.clamped(to: spacingRange), for: spacingKey)
        write(padding.clamped(to: paddingRange), for: paddingKey)
        synchronise()
    }

    static func reset() {
        write(nil, for: spacingKey)
        write(nil, for: paddingKey)
        synchronise()
    }

    private static func read(_ key: CFString) -> Int? {
        for host in [kCFPreferencesCurrentHost, kCFPreferencesAnyHost] {
            let value = CFPreferencesCopyValue(
                key,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                host
            )
            if let number = value as? NSNumber { return number.intValue }
        }
        return nil
    }

    private static func write(_ value: Int?, for key: CFString) {
        CFPreferencesSetValue(
            key,
            value.map(NSNumber.init(value:)),
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
    }

    private static func synchronise() {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
