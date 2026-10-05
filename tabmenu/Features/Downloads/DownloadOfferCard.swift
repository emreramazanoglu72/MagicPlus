//
//  DownloadOfferCard.swift
//  tabmenu
//

import SwiftUI

/// The island, unfolded into a question.
///
/// Everything here is one gesture away from an answer: take it, type a different link because the
/// guess was wrong, or dismiss it. The glyph breathes while the card is up — the one moving thing
/// on the surface, because this is the only state that is waiting on a person rather than
/// reporting something that already happened.
struct DownloadOfferCard: View {
    /// Fixed, and shared with the window controller so it can work out where the card actually
    /// is. A card whose height depends on how long a title happens to be is a card nothing can
    /// hit-test against.
    static let contentHeight: CGFloat = 106

    let offer: DownloadOffer
    let onAccept: () -> Void
    let onManual: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: Island.Space.m) {
            header
            actions
        }
        .padding(.horizontal, Island.Space.l)
        .padding(.bottom, Island.Space.l)
        .frame(height: Self.contentHeight, alignment: .top)
        .onAppear { hasAppeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            offer.isMedia
                ? String(localized: "Media found", comment: "Notch activity")
                : String(localized: "Link found", comment: "Notch activity")
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Island.Space.m) {
            glyph

            VStack(alignment: .leading, spacing: 3) {
                Text(offer.title)
                    .font(Island.Text.title)
                    .foregroundStyle(Island.Ink.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Island.Space.xs) {
                    Text(offer.host)
                        .font(Island.Text.caption)
                        .foregroundStyle(Island.Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let detail = offer.detail {
                        Text("·")
                            .font(Island.Text.caption)
                            .foregroundStyle(Island.Ink.tertiary)
                        Text(detail)
                            .font(Island.Text.numericSmall)
                            .foregroundStyle(Island.Signal.info)
                            .contentTransition(.numericText())
                    }
                }
            }

            Spacer(minLength: 0)

            // Dismissal sits away from the two things you might actually want, so it is never
            // the button under the pointer by accident.
            IslandIconButton(
                systemImage: "xmark",
                help: String(localized: "Dismiss", comment: "Closes the download offer"),
                size: 24,
                action: onDismiss
            )
        }
    }

    /// A disc that holds the kind, pulsing gently while the question stands.
    private var glyph: some View {
        ZStack {
            Circle()
                .fill(Island.Signal.info.opacity(0.16))
                .frame(width: 40, height: 40)

            Circle()
                .strokeBorder(Island.Signal.info.opacity(hasAppeared ? 0.55 : 0), lineWidth: 1.5)
                .frame(width: 40, height: 40)
                .scaleEffect(hasAppeared && !reduceMotion ? 1.22 : 1)
                .opacity(hasAppeared && !reduceMotion ? 0 : 1)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                    value: hasAppeared
                )

            Image(systemName: offer.symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Island.Signal.info)
                .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: Island.Space.s) {
            IslandChipButton(
                title: offer.optionCount > 1 ? "Choose quality" : "Download",
                isProminent: true,
                action: onAccept
            )

            // The guess is wrong often enough to deserve a way out that is not "give up".
            IslandChipButton(title: "Paste a link", action: onManual)

            Spacer(minLength: 0)

            if offer.optionCount > 1 {
                Text(String(localized: "\(offer.optionCount) formats", comment: "How many qualities were found"))
                    .font(Island.Text.caption)
                    .foregroundStyle(Island.Ink.tertiary)
            }
        }
    }
}
