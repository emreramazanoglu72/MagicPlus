//
//  NotchIslandView.swift
//  tabmenu
//

import SwiftUI

/// The island itself: sized from the hardware notch outwards.
///
/// At rest it *is* the notch — same width, same height, pure black — so there is nothing to
/// see. Activities widen it into a capsule that flanks the cut-out; hovering unfolds the panel
/// beneath it. One silhouette animates through all three, so the island appears to stretch out
/// of the hardware rather than a new view appearing over it.
///
/// The strip level with the notch stays pure black at every stage; only the body below it
/// lifts off black and takes a hairline edge. That single rule is what keeps the illusion.
struct NotchIslandView: View {
    @Bindable var model: NotchModel
    let anchorSize: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var morph

    private static var expandedWidth: CGFloat { expandedWidthValue }
    /// Narrower than the panel: a question is a sentence, not a workspace.
    private static var offerWidth: CGFloat { offerWidthValue }
    private static var offerCapsuleSideWidth: CGFloat { offerCapsuleSideWidthValue }
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
    /// Widths and heights the controller needs to know where the island physically is, so it can
    /// take the pointer over the island and nowhere else.
    static let offerWidthValue: CGFloat = 430
    /// Room either side of the notch for the capsule an offer arrives as.
    static let offerCapsuleSideWidthValue: CGFloat = 118
    static let expandedWidthValue: CGFloat = 578
    /// Rail, its spacing, the pane and the bottom padding. The rail's own height is measured
    /// rather than assumed — `PaneHeightTests` pins this to what the panel actually lays out,
    /// because the controller captures the pointer over exactly this region.
    static let railHeight: CGFloat = 30
    static let panelContentHeight: CGFloat =
        railHeight + Island.Space.m + Island.paneHeight + Island.Space.l

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
                    .padding(.horizontal, Island.Space.l)
                    .padding(.bottom, Island.Space.l)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }

            if let offer = model.offer, model.isOffering, model.isOfferExpanded {
                DownloadOfferCard(
                    offer: offer,
                    onAccept: model.acceptOffer,
                    onManual: model.enterLinkManually,
                    onDismiss: model.declineOffer
                )
                // Grows out of the notch rather than fading in over it: the card is the island
                // stretching, which is the whole illusion.
                .transition(.asymmetric(
                    insertion: .offset(y: -14).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: .top)),
                    removal: .opacity.combined(with: .offset(y: -8))
                ))
            }
        }
        .frame(width: size.width)
        .background {
            // A card is as much a surface as the panel is: it lifts off black and takes an edge.
            IslandSurface(
                shape: shape,
                isExpanded: model.isExpanded || (model.isOffering && model.isOfferExpanded),
                stripHeight: topRowHeight
            )
        }
        .clipShape(shape)
        .overlay {
            if model.isDropTargeted {
                shape.stroke(Island.Signal.info, lineWidth: 2)
            }
        }
        .motion(Motion.island, value: model.stage)
        .motion(Motion.island, value: model.activity)
        .motion(Motion.island, value: model.offer)
        .motion(Motion.island, value: model.isOfferExpanded)
        .motion(Motion.island, value: model.hasIdleIndicator)
        .motion(Motion.snappy, value: model.isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.acceptDrop(urls)
            return true
        } isTargeted: { targeted in
            model.isDropTargeted = targeted
            if targeted { model.prepareForDrop() }
        }
    }

    private var shape: NotchShape {
        NotchShape(bottomRadius: bottomRadius, shoulderRadius: shoulderRadius)
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
        .padding(.horizontal, model.stage == .idle && !model.hasIdleIndicator ? 0 : Self.contentInset)
    }

    @ViewBuilder
    private var leading: some View {
        switch model.stage {
        case .idle:
            if model.hasIdleIndicator {
                HStack(spacing: Island.Space.xs) {
                    if model.micLive {
                        Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(model.micMuted ? Island.Signal.danger : Island.Signal.warning)
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
        case .offer:
            HStack(spacing: Island.Space.s) {
                Image(systemName: model.offer?.symbolName ?? "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Island.Signal.info)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: model.offer)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        case .expanded:
            ExpandedLeadingView(model: model, morph: morph)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.stage {
        case .idle:
            if model.hasIdleIndicator {
                HStack(spacing: Island.Space.xs) {
                    Spacer(minLength: 0)
                    if model.cameraLive {
                        Circle()
                            .fill(Island.Signal.success)
                            .frame(width: 7, height: 7)
                            .shadow(color: Island.Signal.success.opacity(0.8), radius: 4)
                            .accessibilityLabel("Camera in use")
                    }
                    // A transfer nobody is watching still deserves somewhere to be seen.
                    if model.isDownloading {
                        IslandProgressRing(value: model.downloads.overallProgress, diameter: 13)
                    }
                }
            }
        case .activity:
            if let activity = model.activity {
                ActivityTrailingView(activity: activity, model: model)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        case .offer:
            HStack(spacing: Island.Space.s) {
                Spacer(minLength: 0)

                if model.isOfferExpanded {
                    // The card below carries the title, the site and the size. Repeating any of
                    // it here would only repeat it truncated.
                    Text(model.offer?.isMedia == true
                         ? String(localized: "Media found", comment: "Notch activity")
                         : String(localized: "Link found", comment: "Notch activity"))
                        .font(Island.Text.label)
                        .foregroundStyle(Island.Ink.secondary)
                        .lineLimit(1)
                } else {
                    // The same two lines every other capsule uses, so a glance lands in the
                    // place it always does.
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(model.offer?.isMedia == true
                             ? String(localized: "Media found", comment: "Notch activity")
                             : String(localized: "Link found", comment: "Notch activity"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Island.Ink.primary)

                        if let detail = model.offer?.detail {
                            Text(detail)
                                .font(Island.Text.numericSmall)
                                .foregroundStyle(Island.Ink.secondary)
                        }
                    }
                    .lineLimit(1)

                    // A word would cost the room the label needs; a chevron says the same thing.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Island.Ink.tertiary)
                }
            }
            .transition(.opacity)
        case .expanded:
            ExpandedTrailingView(model: model)
                .transition(.opacity)
        }
    }

    // MARK: - Geometry

    private var size: CGSize {
        switch model.stage {
        case .idle:
            model.hasIdleIndicator
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
        case .offer:
            // A capsule until it is pointed at, then the full card.
            model.isOfferExpanded
                ? CGSize(width: Self.offerWidth, height: anchorSize.height + Self.verticalPadding)
                : CGSize(
                    width: anchorSize.width + Self.offerCapsuleSideWidth * 2 + Self.contentInset * 2,
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
        case .idle: model.hasIdleIndicator ? anchorSize.height + 6 : anchorSize.height
        case .activity, .offer, .expanded: anchorSize.height + Self.verticalPadding
        }
    }

    /// Idle keeps the notch's own soft corner; an activity reads as a pill; the panel relaxes
    /// into a rounded sheet.
    private var bottomRadius: CGFloat {
        switch model.stage {
        case .idle: (anchorSize.height + (model.hasIdleIndicator ? 6 : 0)) / 2
        case .activity: (anchorSize.height + Self.verticalPadding) / 2
        case .offer: model.isOfferExpanded
            ? Island.Radius.panel
            : (anchorSize.height + Self.verticalPadding) / 2
        case .expanded: Island.Radius.panel
        }
    }

    /// No shoulders at rest — the silhouette must match the hardware exactly. The hardware
    /// indicator counts as an activity for the silhouette.
    private var shoulderRadius: CGFloat {
        model.stage == .idle && !model.hasIdleIndicator ? 0 : Self.shoulder
    }
}
