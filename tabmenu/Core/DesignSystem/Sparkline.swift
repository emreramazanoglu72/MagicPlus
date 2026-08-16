//
//  Sparkline.swift
//  tabmenu
//

import Charts
import SwiftUI

/// Compact history graph. Values are expected in the `0...1` range.
struct Sparkline: View {
    let samples: [Double]
    var tint: Color
    var height: CGFloat = 28

    var body: some View {
        Chart(Array(samples.enumerated()), id: \.offset) { index, value in
            AreaMark(
                x: .value("Sample", index),
                yStart: .value("Floor", 0),
                yEnd: .value("Value", value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [tint.opacity(0.35), tint.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Sample", index),
                y: .value("Value", value)
            )
            .foregroundStyle(tint)
            .lineStyle(.init(lineWidth: 1.6, lineCap: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1.05)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.background(.clear) }
        .frame(height: height)
        .motion(Motion.metric, value: samples.last ?? 0)
        .accessibilityHidden(true)
    }
}
