//
//  StartMenuView.swift
//  MagicPlus
//

import AppKit
import SwiftUI

/// Search, everything installed, and the commands that end a session.
///
/// Drawn in the same language as the strip it opens out of: dark glass, no dividers, no outlines
/// around groups. The two bands of chrome — the search field at the top and the session row at the
/// bottom — are told apart from the grid between them by being a shade darker, which is what a line
/// across the panel used to do and does worse.
///
/// The one place a filled rectangle is right is the selected tile, because a grid needs to say which
/// cell Return will open. It wears that application's own colour rather than grey, the same colour
/// the bar uses to mark what is in front.
struct StartMenuView: View {
    let model: StartMenuPanel.Model
    var onLaunch: (LaunchableApp) -> Void
    var onSession: (SessionCommand) -> Void

    @FocusState private var searchFocused: Bool

    /// Shared with the panel, which moves the selection a row at a time. Two answers to "how many
    /// across" would be two disagreeing answers to "what does the down arrow do".
    static let columnCount = 6

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: Self.columnCount)
    }

    private var style: DockStyle { model.style }

    var body: some View {
        VStack(spacing: 0) {
            search
            content
            footer
        }
        .background { surface }
        .environment(\.colorScheme, style.contentScheme ?? .dark)
        .onAppear { searchFocused = true }
    }

    /// The same glass as the bar, a little less sheer — a panel this size has paragraphs of text on
    /// it, and text over a busy wallpaper needs more between it and the wallpaper than a strip does.
    @ViewBuilder
    private var surface: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill((style.tint ?? .black).opacity(min(1, style.backgroundOpacity + 0.2)))
        }
    }

    // MARK: - Search

    private var search: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(
                String(localized: "Search applications", comment: "Start menu search field"),
                text: Binding(get: { model.query }, set: { model.query = $0; model.selection = 0 })
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($searchFocused)
            .onSubmit {
                guard model.results.indices.contains(model.selection) else { return }
                onLaunch(model.results[model.selection])
            }

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.selection = 0
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear", comment: "Start menu search field"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            Capsule().fill(.primary.opacity(0.08))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.black.opacity(0.14))
    }

    // MARK: - The grid

    @ViewBuilder
    private var content: some View {
        let results = model.results
        if results.isEmpty {
            nothingMatches
        } else {
            grid(results)
        }
    }

    private var nothingMatches: some View {
        VStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing matches")
                .font(.callout.weight(.medium))
            Text("No installed application has that in its name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Applications that are already open, then the rest.
    ///
    /// Both sections index into one array, so the arrow keys and the grid cannot disagree about
    /// which tile is selected — two parallel lists reliably produce exactly that bug.
    private func grid(_ results: [LaunchableApp]) -> some View {
        let open = model.openCount(in: results)

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if open > 0 {
                    header(String(localized: "Open", comment: "Start menu section: running applications"), count: open)
                    tiles(results, range: 0..<open)
                }

                if open < results.count {
                    header(
                        String(localized: "Applications", comment: "Start menu section: everything installed"),
                        count: results.count - open
                    )
                    tiles(results, range: open..<results.count)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }

    private func tiles(_ results: [LaunchableApp], range: Range<Int>) -> some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(range, id: \.self) { index in
                StartMenuTile(
                    app: results[index],
                    isSelected: index == model.selection,
                    onOpen: { onLaunch(results[index]) },
                    // Hovering moves the selection, so the arrow keys and the pointer never
                    // disagree about what Return will open.
                    onHover: { model.selection = index }
                )
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Initials(name: NSFullUserName())

            Text(NSFullUserName())
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            ForEach(SessionCommand.allCases) { command in
                SessionButton(command: command) { onSession(command) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.14))
    }
}

// MARK: - Pieces

/// One application in the grid.
///
/// Not `private` so the snapshot test can lay a few of these out itself: `ImageRenderer` draws
/// nothing at all for a `LazyVGrid`, and a design nobody can look at is a design nobody can judge.
struct StartMenuTile: View {
    let app: LaunchableApp
    let isSelected: Bool
    var onOpen: () -> Void
    var onHover: () -> Void

    /// The application's own colour, so the selection is recognisably that application rather than
    /// a grey box that happens to be under the pointer.
    private var accent: Color {
        DockAccent.color(for: AppLauncher.icon(for: app, size: 32), key: app.id) ?? .white
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 6) {
                Image(nsImage: AppLauncher.icon(for: app, size: 88))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)

                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 28, alignment: .top)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(accent.opacity(0.22))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(accent.opacity(0.4), lineWidth: 0.5)
                        }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
        .motion(Motion.snappy, value: isSelected)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The user's initials, standing in for an account picture.
///
/// The real one lives in Open Directory and needs a round trip to get at; two letters in a circle
/// says the same thing about whose session this is and cannot fail.
private struct Initials: View {
    let name: String

    private var letters: String {
        let words = name.split(separator: " ").prefix(2)
        let initials = words.compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }

    var body: some View {
        Text(letters)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background {
                Circle().fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.mix(with: .black, by: 0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .accessibilityHidden(true)
    }
}

/// One of the commands that ends a session.
///
/// Shut down turns red under the pointer. It is the one button here that cannot be taken back, and
/// a row of five identical grey glyphs where one of them switches the machine off is a row that
/// gets misclicked.
private struct SessionButton: View {
    let command: SessionCommand
    var action: () -> Void

    @State private var isHovered = false

    private var tint: Color {
        guard isHovered else { return .secondary }
        return command == .shutDown ? .red : .primary
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: command.symbolName)
                .font(.system(size: 12.5))
                .foregroundStyle(tint)
                .frame(width: 30, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((command == .shutDown ? Color.red : .primary).opacity(isHovered ? 0.14 : 0))
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .help(command.title)
        .accessibilityLabel(command.title)
    }
}
