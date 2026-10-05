//
//  ColorHex.swift
//  tabmenu
//

import AppKit
import SwiftUI

/// Colours the user picks are stored as hex strings, which survive a defaults round trip
/// where an `NSColor` archive would age badly.
extension Color {
    init(hex: String, fallback: Color = .accentColor) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else {
            self = fallback
            return
        }
        self.init(
            .sRGB,
            red: Double((number & 0xFF0000) >> 16) / 255,
            green: Double((number & 0x00FF00) >> 8) / 255,
            blue: Double(number & 0x0000FF) / 255
        )
    }

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return "000000" }
        let red = Int((components.redComponent * 255).rounded())
        let green = Int((components.greenComponent * 255).rounded())
        let blue = Int((components.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}
