//
//  DockAccent.swift
//  MagicPlus
//

import AppKit
import SwiftUI

/// The colour an application's icon is mostly made of.
///
/// The bar carries a wash of it, so switching from Xcode to Spotify to Safari shifts the strip's
/// hue with you. That is the whole point of reading it: a bar that answers to what you are doing
/// looks alive, and a fixed grey one looks like a control that has been switched off.
///
/// Not an average of the pixels — averaging a colourful icon returns mud, because opposite hues
/// cancel. The pixels are binned by hue, the heaviest bin wins, and its colour comes back with
/// saturation and brightness pulled into a range that reads on dark glass. An icon with no colour
/// in it at all — Terminal, most menu-bar utilities — returns `nil` rather than a made-up hue, and
/// the bar stays neutral for it.
@MainActor
enum DockAccent {
    private static var cache: [String: Color?] = [:]

    /// - Parameter key: What to remember the answer under, normally a bundle identifier. Reading
    ///   pixels is cheap but not free, and this is asked once per frame the bar draws.
    static func color(for image: NSImage?, key: String) -> Color? {
        guard !key.isEmpty else { return image.flatMap(dominantColor) }
        if let cached = cache[key] { return cached }

        let colour = image.flatMap(dominantColor)
        // An icon is a couple of dozen entries at most; a cache without a ceiling is a leak.
        if cache.count > 80 { cache.removeAll() }
        cache[key] = colour
        return colour
    }

    // MARK: - Reading the icon

    /// Sampled at 16×16. An icon's identity survives that: what is being looked for is which hue
    /// covers the most of it, and no amount of detail changes that answer.
    private static let sampleSize = 16

    private static func dominantColor(_ image: NSImage) -> Color? {
        guard let pixels = samples(of: image) else { return nil }

        // Twelve bins of thirty degrees. Fewer and green swallows cyan; more and a single icon's
        // gradient splits itself across neighbouring bins and loses to a flat one.
        let binCount = 12
        var weight = [Double](repeating: 0, count: binCount)
        var x = [Double](repeating: 0, count: binCount)
        var y = [Double](repeating: 0, count: binCount)
        var saturation = [Double](repeating: 0, count: binCount)
        var brightness = [Double](repeating: 0, count: binCount)

        for pixel in pixels {
            guard let hsb = pixel.hsb else { continue }
            let bin = min(binCount - 1, Int(hsb.hue * Double(binCount)))
            // A pale wash counts for less than a solid block of the same hue.
            let contribution = hsb.saturation * hsb.brightness
            weight[bin] += contribution
            x[bin] += cos(hsb.hue * 2 * .pi) * contribution
            y[bin] += sin(hsb.hue * 2 * .pi) * contribution
            saturation[bin] += hsb.saturation * contribution
            brightness[bin] += hsb.brightness * contribution
        }

        guard let winner = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[winner] > 0.4
        else { return nil }

        // Circular mean inside the bin, so the hue that comes back is the icon's own rather than
        // the bin's centre.
        var hue = atan2(y[winner], x[winner]) / (2 * .pi)
        if hue < 0 { hue += 1 }

        let total = weight[winner]
        return Color(
            hue: hue,
            // Pulled into a band that reads as a tint on dark glass: too grey and the wash is
            // invisible, too pure and the bar looks like a warning.
            saturation: min(max(saturation[winner] / total, 0.42), 0.88),
            brightness: min(max(brightness[winner] / total, 0.72), 1)
        )
    }

    private struct Sample {
        let red: Double
        let green: Double
        let blue: Double

        /// `nil` for anything too grey or too dark to carry a hue worth using.
        var hsb: (hue: Double, saturation: Double, brightness: Double)? {
            let high = max(red, green, blue)
            let low = min(red, green, blue)
            let delta = high - low
            guard high > 0.18, delta > 0.08 else { return nil }

            let saturation = delta / high
            guard saturation > 0.18 else { return nil }

            var hue: Double
            switch high {
            case red: hue = (green - blue) / delta
            case green: hue = 2 + (blue - red) / delta
            default: hue = 4 + (red - green) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
            return (hue, saturation, high)
        }
    }

    private static func samples(of image: NSImage) -> [Sample]? {
        var rect = CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        else { return nil }

        let count = sampleSize * sampleSize
        var bytes = [UInt8](repeating: 0, count: count * 4)
        guard let context = CGContext(
            data: &bytes,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: rect)

        return (0..<count).compactMap { index in
            let offset = index * 4
            let alpha = Double(bytes[offset + 3]) / 255
            // A rounded icon is mostly corners; the transparent ones say nothing about its colour.
            guard alpha > 0.75 else { return nil }
            return Sample(
                red: Double(bytes[offset]) / 255 / alpha,
                green: Double(bytes[offset + 1]) / 255 / alpha,
                blue: Double(bytes[offset + 2]) / 255 / alpha
            )
        }
    }
}
