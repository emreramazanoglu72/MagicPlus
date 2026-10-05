//
//  ModuleSettingsView.swift
//  tabmenu
//

import SwiftUI

/// One place to decide which parts of the app are running.
///
/// MagicPlus is a dozen small utilities sharing a menu bar item, and most people want two or
/// three of them. Until now five had a switch of their own — each in whichever tab it lived in —
/// and the rest could not be turned off at all, which meant paying for features nobody asked for
/// in samplers, observers and system-wide keys.
struct ModuleSettingsView: View {
    let environment: AppEnvironment

    private var preferences: Preferences { environment.preferences }

    var body: some View {
        Form {
            Section {
                ForEach(AppModule.allCases) { module in
                    row(for: module)
                }
            } footer: {
                Text("Switching a module off releases what it was holding — its samplers stop, its observers come off, its menu bar items go back, and its keyboard shortcuts are handed back to the system. Each module keeps its own detailed settings in the other tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(for module: AppModule) -> some View {
        Toggle(isOn: binding(for: module)) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: module.symbolName)
                    .font(.system(size: 14))
                    .foregroundStyle(preferences.isEnabled(module) ? AnyShapeStyle(Accent.windows.gradient) : AnyShapeStyle(.secondary))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title)
                    Text(module.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Every change goes through the one place that knows how to act on it, so a switch here and
    /// the same switch in a feature's own tab cannot disagree.
    private func binding(for module: AppModule) -> Binding<Bool> {
        Binding(
            get: { preferences.isEnabled(module) },
            set: { enabled in
                preferences.setEnabled(enabled, for: module)
                environment.applyModules()
            }
        )
    }
}
