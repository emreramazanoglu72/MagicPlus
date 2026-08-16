//
//  OnboardingView.swift
//  tabmenu
//

import SwiftUI

/// First-run screen that explains each permission and tracks it live, so the user can see
/// a row flip to Granted the moment they allow it in System Settings.
struct OnboardingView: View {
    let catalog: PermissionCatalog
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(PermissionKind.allCases) { kind in
                        PermissionRow(
                            kind: kind,
                            state: catalog.state(for: kind),
                            onGrant: { catalog.request(kind) },
                            onOpenSettings: { catalog.openSettings(for: kind) }
                        )
                    }
                }
                .padding(16)
            }

            footer
        }
        .frame(width: 520, height: 580)
        .onAppear { catalog.startPolling() }
        .onDisappear { catalog.stopPolling() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

            Text("Welcome to MagicPlus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            Text("Windows, clipboard, previews and system stats in one place.\nGrant what you need — each feature says what it uses.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background {
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
            .overlay(.black.opacity(0.25))
        }
    }

    private var footer: some View {
        HStack {
            Label(
                catalog.isReady ? "Ready to go" : "Accessibility is required",
                systemImage: catalog.isReady ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(catalog.isReady ? .green : .orange)
            .motion(Motion.snappy, value: catalog.isReady)

            Spacer()

            Button("Continue", action: onFinish)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(.bar)
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(state.isGranted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
                .background(
                    state.isGranted ? AnyShapeStyle(Color.green.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: .rect(cornerRadius: 8)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title)
                        .font(.callout.weight(.medium))
                    if kind.isRequired {
                        Text("Required")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: .capsule)
                    }
                }

                Text(kind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = kind.fallbackNote, !state.isGranted {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            controls
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
        .motion(Motion.snappy, value: state)
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .trailing, spacing: 5) {
            switch state {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)

            case .undetermined where kind == .automation:
                Text("Asked on first use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Settings", action: onOpenSettings)
                    .buttonStyle(.link)
                    .font(.caption)

            case .undetermined, .denied:
                Button("Grant", action: onGrant)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Settings", action: onOpenSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(width: 92, alignment: .trailing)
    }
}
