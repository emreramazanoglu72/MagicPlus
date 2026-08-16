//
//  GenerateAppIcon.swift
//  tabmenu
//
//  Draws the app icon and exports every slot of AppIcon.appiconset, so the artwork stays
//  editable source rather than opaque bitmaps. Regenerate after changing the design:
//
//      swiftc -O Scripts/GenerateAppIcon.swift -o /tmp/generate-app-icon
//      /tmp/generate-app-icon tabmenu/Assets.xcassets/AppIcon.appiconset
//
//  Kept outside the tabmenu/ folder because that folder is a synchronized group: anything
//  inside it is compiled into the app.
//

import AppKit
import SwiftUI

/// App icon artwork: a macOS squircle carrying a three-pane window layout, the app's core idea.
struct IconArtwork: View {
    let size: CGFloat

    /// Everything is expressed against Apple's 1024pt icon grid and scaled down, so every
    /// exported size shares one geometry.
    private var unit: CGFloat { size / 1024 }
    private var body_: CGFloat { 824 * unit }
    private var isTiny: Bool { size < 64 }

    private var glyphSide: CGFloat { 452 * unit }
    private var gap: CGFloat { max(1, 26 * unit) }
    private var tileRadius: CGFloat { max(1, 40 * unit) }

    var body: some View {
        ZStack {
            squircle
            glyph
        }
        .frame(width: size, height: size)
    }

    private var squircle: some View {
        RoundedRectangle(cornerRadius: 185.4 * unit, style: .continuous)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.36, green: 0.55, blue: 1.00), location: 0),
                        .init(color: Color(red: 0.30, green: 0.36, blue: 0.95), location: 0.52),
                        .init(color: Color(red: 0.45, green: 0.25, blue: 0.86), location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                // Light gathering along the top edge keeps the body from reading as flat.
                RoundedRectangle(cornerRadius: 185.4 * unit, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(isTiny ? 0.10 : 0.22), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            }
            .overlay {
                if !isTiny {
                    RoundedRectangle(cornerRadius: 185.4 * unit, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 2.5 * unit)
                }
            }
            .frame(width: body_, height: body_)
            .shadow(
                color: .black.opacity(isTiny ? 0.18 : 0.30),
                radius: 26 * unit,
                y: 18 * unit
            )
    }

    /// One tall pane beside two stacked ones: the tiling arrangement, legible even at 16px.
    private var glyph: some View {
        HStack(spacing: gap) {
            tile(opacity: 0.97)
                .frame(width: (glyphSide - gap) * 0.5)

            VStack(spacing: gap) {
                tile(opacity: 0.84)
                tile(opacity: 0.66)
            }
        }
        .frame(width: glyphSide, height: glyphSide)
        .shadow(color: .black.opacity(isTiny ? 0 : 0.18), radius: 14 * unit, y: 8 * unit)
    }

    private func tile(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: tileRadius, style: .continuous)
            .fill(.white.opacity(opacity))
    }
}

@MainActor
func render(size: CGFloat, to url: URL) throws {
    let renderer = ImageRenderer(content: IconArtwork(size: size))
    renderer.scale = 1
    renderer.isOpaque = false

    guard let cgImage = renderer.cgImage else {
        throw NSError(domain: "GenerateIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "render failed at \(size)"])
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: size, height: size)

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
    }
    try data.write(to: url)
}

/// Slot name to pixel size, following the layout `iconutil` expects.
let slots: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

try MainActor.assumeIsolated {
    for slot in slots {
        let url = destination.appendingPathComponent("\(slot.name).png")
        try render(size: slot.pixels, to: url)
        print("wrote \(slot.name).png (\(Int(slot.pixels))px)")
    }
}
