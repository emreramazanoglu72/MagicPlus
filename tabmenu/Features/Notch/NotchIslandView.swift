//
//  NotchIslandView.swift
//  tabmenu
//

import SwiftUI

/// The island itself: pure black, sized from the hardware notch outwards.
///
/// At rest it is exactly the notch, so nothing is visible at all. Activities widen it into a
/// capsule that flanks the notch; hovering unfolds the full panel beneath it. Every state
/// change animates the same silhouette, so the shape appears to stretch out of the hardware
/// rather than a new view appearing.
struct NotchIslandView: View {
    let model: NotchModel
    let anchorSize: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var morph

    private static let expandedWidth: CGFloat = 480
    /// Radius of the concave shoulders where the island meets the menu bar.
    private static let shoulder: CGFloat = 10

    // Shared with NotchWindowController, which mirrors the activity capsule's geometry for
    // click hit-testing — the two must never drift apart.
    /// Breathing room between those shoulders and the content, so nothing sits on the curve.
    static let contentInset: CGFloat = 18
    /// Extra height over the notch itself, so content is not pinned to the top and bottom edges.
    static let verticalPadding: CGFloat = 14
    /// Side-panel width assumed when no activity is set.
    static let defaultSideWidth: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Island

    private var island: some View {
        VStack(spacing: 0) {
            topRow

            if model.isExpanded {
                NotchPanelContent(model: model, morph: morph)
                    .padding(.horizontal, Self.contentInset)
                    .padding(.bottom, Self.contentInset)
                    .transition(.opacity.combined(with: .offset(y: -10)))
            }
        }
        .frame(width: size.width)
        .background {
            NotchShape(bottomRadius: bottomRadius, shoulderRadius: shoulderRadius)
                .fill(.black)
                .shadow(color: .black.opacity(model.isExpanded ? 0.5 : 0.25), radius: model.isExpanded ? 24 : 8, y: 6)
        }
        .clipShape(NotchShape(bottomRadius: bottomRadius, shoulderRadius: shoulderRadius))
        .overlay {
            if model.isDropTargeted {
                NotchShape(bottomRadius: bottomRadius, shoulderRadius: shoulderRadius)
                    .stroke(Accent.windows, lineWidth: 2)
            }
        }
        .motion(Motion.island, value: model.stage)
        .motion(Motion.island, value: model.activity)
        .motion(Motion.island, value: model.hasHardwareIndicator)
        .motion(Motion.snappy, value: model.isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.acceptDrop(urls)
            return true
        } isTargeted: { targeted in
            model.isDropTargeted = targeted
            if targeted { model.prepareForDrop() }
        }
    }

    /// The strip level with the notch. Content sits either side of the physical cut-out,
    /// which stays empty.
    private var topRow: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: sideWidth, alignment: .leading)

            Color.clear
                .frame(width: anchorSize.width)

            trailing
                .frame(width: sideWidth, alignment: .trailing)
        }
        .frame(height: topRowHeight)
        // Must match the inset used to derive `sideWidth`, or the gap left for the physical
        // notch drifts off centre.
        .padding(.horizontal, model.stage == .idle && !model.hasHardwareIndicator ? 0 : Self.contentInset)
    }

    @ViewBuilder
    private var leading: some View {
        switch model.stage {
        case .idle:
            if model.hasHardwareIndicator {
                HStack(spacing: 4) {
                    if model.micLive {
                        Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(model.micMuted ? .red : .orange)
                            .contentTransition(.symbolEffect(.replace))
                            .accessibilityLabel(model.micMuted ? "Microphone muted" : "Microphone in use")
                    }
                    Spacer(minLength: 0)
                }
            }
        case .activity:
            if let activity = model.activity {
                ActivityLeadingView(activity: activity, model: model, morph: morph)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        case .expanded:
            ExpandedLeadingView(model: model, morph: morph)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.stage {
        case .idle:
            if model.hasHardwareIndicator {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if model.cameraLive {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                            .shadow(color: .green.opacity(0.7), radius: 3)
                            .accessibilityLabel("Camera in use")
                    }
                }
            }
        case .activity:
            if let activity = model.activity {
                ActivityTrailingView(activity: activity, model: model)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        case .expanded:
            ExpandedTrailingView(model: model)
                .transition(.opacity)
        }
    }

    // MARK: - Geometry

    private var size: CGSize {
        switch model.stage {
        case .idle:
            model.hasHardwareIndicator
                ? CGSize(
                    width: anchorSize.width + 28 * 2 + Self.contentInset * 2,
                    height: anchorSize.height + 6
                )
                : CGSize(width: anchorSize.width, height: anchorSize.height)
        case .activity:
            CGSize(
                width: anchorSize.width + (model.activity?.sideWidth ?? Self.defaultSideWidth) * 2 + Self.contentInset * 2,
                height: anchorSize.height + Self.verticalPadding
            )
        case .expanded:
            CGSize(width: Self.expandedWidth, height: anchorSize.height + Self.verticalPadding)
        }
    }

    private var sideWidth: CGFloat {
        max(0, (size.width - anchorSize.width) / 2 - Self.contentInset)
    }

    private var topRowHeight: CGFloat {
        switch model.stage {
        case .idle: model.hasHardwareIndicator ? anchorSize.height + 6 : anchorSize.height
        case .activity, .expanded: anchorSize.height + Self.verticalPadding
        }
    }

    /// Idle keeps the notch's own soft corner; an activity reads as a pill; the panel
    /// relaxes into a rounded sheet.
    private var bottomRadius: CGFloat {
        switch model.stage {
        case .idle: (anchorSize.height + (model.hasHardwareIndicator ? 6 : 0)) / 2
        case .activity: (anchorSize.height + Self.verticalPadding) / 2
        case .expanded: 28
        }
    }

    /// No shoulders at rest — the silhouette must match the hardware exactly. The hardware
    /// indicator counts as an activity for the silhouette.
    private var shoulderRadius: CGFloat {
        model.stage == .idle && !model.hasHardwareIndicator ? 0 : Self.shoulder
    }
}
