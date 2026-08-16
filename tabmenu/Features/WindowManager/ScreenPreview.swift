//
//  ScreenPreview.swift
//  tabmenu
//

import SwiftUI

/// Miniature desktop that shows where a zone will place the window.
///
/// `WindowZone` geometry is expressed with a top-left origin, which is also SwiftUI's
/// coordinate space, so zone frames map onto the preview without conversion.
struct ScreenPreview: View {
    let zone: WindowZone?
    let gap: Double
    var tint: Color = Accent.windows
    var isEmphasised = false

    /// Gap is authored in points against a typical display width; scaling it by the same
    /// ratio keeps the preview honest about how much padding was chosen.
    private static let referenceScreenWidth: Double = 1440

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let inset = (gap / Self.referenceScreenWidth) * proxy.size.width / 2

            ZStack(alignment: .top) {
                wallpaper
                menuBarStrip

                if let zone {
                    windowChrome(in: workArea(of: bounds), zone: zone, inset: inset)
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        .scaleEffect(isEmphasised ? 1.02 : 1)
        .motion(Motion.snappy, value: isEmphasised)
        .accessibilityHidden(true)
    }

    /// The menu bar strip is excluded, mirroring how zones respect the real visible frame.
    private func workArea(of bounds: CGRect) -> CGRect {
        let menuBarHeight = bounds.height * 0.07
        return CGRect(
            x: bounds.minX,
            y: bounds.minY + menuBarHeight,
            width: bounds.width,
            height: bounds.height - menuBarHeight
        )
    }

    private var wallpaper: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.6, 0.4], [1, 0.5],
                [0, 1], [0.4, 1], [1, 1]
            ],
            colors: [
                .indigo, .blue, .purple,
                .blue, .cyan, .indigo,
                .teal, .blue, .purple
            ]
        )
        .opacity(0.5)
        .overlay(.black.opacity(0.4))
    }

    private var menuBarStrip: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                Spacer()
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(.white.opacity(0.5))
                        .frame(width: proxy.size.width * 0.035, height: 1.5)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: proxy.size.height * 0.07)
            .background(.black.opacity(0.2))
        }
    }

    private func windowChrome(in area: CGRect, zone: WindowZone, inset: CGFloat) -> some View {
        let frame = zone
            .frame(in: area.insetBy(dx: inset, dy: inset))
            .insetBy(dx: inset, dy: inset)

        return VStack(spacing: 0) {
            titleBar
            contentLines
        }
        .background(Color(white: 0.97))
        .clipShape(.rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(tint.opacity(0.9), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
        .frame(width: max(frame.width, 10), height: max(frame.height, 10))
        .position(x: frame.midX, y: frame.midY)
        .motion(Motion.fluid, value: frame)
    }

    private var titleBar: some View {
        HStack(spacing: 3) {
            ForEach([Color.red, .yellow, .green], id: \.self) { color in
                Circle().fill(color).frame(width: 4, height: 4)
            }
            Spacer()
        }
        .padding(.horizontal, 5)
        .frame(height: 12)
        .background(Color(white: 0.88))
    }

    /// Suggests window content without pretending to be a real screenshot.
    private var contentLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color(white: 0.75))
                    .frame(height: 3)
                    .padding(.trailing, index == 2 ? 24 : 0)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}
