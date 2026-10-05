//
//  MenuBarSettingsView.swift
//  tabmenu
//

import SwiftUI

/// Settings pane for the menu bar sections, the strip that shows them and the bar's own look.
struct MenuBarSettingsView: View {
    let environment: AppEnvironment

    @Bindable private var preferences: Preferences

    @State private var spacing = MenuBarSpacing.spacing
    @State private var selectionPadding = MenuBarSpacing.padding
    @State private var hasAppliedSpacing = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.preferences = environment.preferences
    }

    var body: some View {
        Form {
            Section("Sections") {
                Toggle("Manage menu bar items", isOn: $preferences.isMenuBarManagerEnabled)
                    .onChange(of: preferences.isMenuBarManagerEnabled) { _, _ in
                        environment.menuBarManager.updateConfiguration()
                    }

                Toggle("Add an always-hidden section", isOn: $preferences.usesAlwaysHiddenSection)
                    .disabled(!preferences.isMenuBarManagerEnabled)
                    .onChange(of: preferences.usesAlwaysHiddenSection) { _, _ in
                        environment.menuBarManager.updateConfiguration()
                    }

                Text("A chevron and a divider are added to the menu bar. Hold ⌘ and drag an item across the divider to hide it; everything to the right of the divider stays on show. Nothing is moved for you, and quitting MagicPlus puts every item back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Revealing") {
                Toggle("Show hidden items in a strip under the menu bar", isOn: $preferences.usesHiddenItemsBar)
                    .disabled(!preferences.isMenuBarManagerEnabled)

                Toggle("Reveal when the pointer is over the menu bar", isOn: $preferences.menuBarShowsOnHover)
                    .disabled(!preferences.isMenuBarManagerEnabled)
                    .onChange(of: preferences.menuBarShowsOnHover) { _, _ in
                        environment.menuBarManager.updateMonitoring()
                    }

                Picker("Hide again", selection: $preferences.menuBarRehideStrategy) {
                    ForEach(MenuBarRehideStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .disabled(!preferences.isMenuBarManagerEnabled)
                .onChange(of: preferences.menuBarRehideStrategy) { _, _ in
                    environment.menuBarManager.updateMonitoring()
                }

                if preferences.menuBarRehideStrategy == .timed {
                    LabeledContent("After") {
                        HStack {
                            Slider(value: $preferences.menuBarRehideDelay, in: 3...60, step: 1)
                            Text("\(Int(preferences.menuBarRehideDelay))s")
                                .font(.callout.monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }

                Text("A revealed section waits for any menu opened from it to close before it folds away again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Tint the menu bar", selection: $preferences.menuBarTintStyle) {
                    ForEach(MenuBarTintStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .onChange(of: preferences.menuBarTintStyle) { _, _ in
                    environment.menuBarAppearance.update()
                }

                if preferences.menuBarTintStyle != .none {
                    ColorPicker("Colour", selection: tintColor, supportsOpacity: false)

                    LabeledContent("Strength") {
                        HStack {
                            Slider(value: $preferences.menuBarTintOpacity, in: 0.05...0.6)
                                .onChange(of: preferences.menuBarTintOpacity) { _, _ in
                                    environment.menuBarAppearance.update()
                                }
                            Text(Format.percent(preferences.menuBarTintOpacity))
                                .font(.callout.monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                        }
                    }

                    Toggle("Draw a line along the bottom", isOn: $preferences.menuBarShowsBorder)
                        .onChange(of: preferences.menuBarShowsBorder) { _, _ in
                            environment.menuBarAppearance.update()
                        }
                }
            }

            Section("Spacing") {
                LabeledContent("Between items") {
                    HStack {
                        Slider(
                            value: spacingBinding,
                            in: Double(MenuBarSpacing.spacingRange.lowerBound)...Double(MenuBarSpacing.spacingRange.upperBound),
                            step: 1
                        )
                        Text("\(spacing)pt")
                            .font(.callout.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                LabeledContent("Around the highlight") {
                    HStack {
                        Slider(
                            value: paddingBinding,
                            in: Double(MenuBarSpacing.paddingRange.lowerBound)...Double(MenuBarSpacing.paddingRange.upperBound),
                            step: 1
                        )
                        Text("\(selectionPadding)pt")
                            .font(.callout.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                HStack {
                    Button("Apply") {
                        MenuBarSpacing.apply(spacing: spacing, padding: selectionPadding)
                        hasAppliedSpacing = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Reset") {
                        MenuBarSpacing.reset()
                        spacing = MenuBarSpacing.defaultSpacing
                        selectionPadding = MenuBarSpacing.defaultPadding
                        hasAppliedSpacing = true
                    }
                    .controlSize(.small)

                    Spacer()
                }

                Text("Spacing is a system-wide setting that each app reads when it creates its menu bar items, so it reaches an app the next time that app launches — log out and back in to change every one of them at once.")
                    .font(.caption)
                    .foregroundStyle(hasAppliedSpacing ? .orange : .secondary)
            }

            Section("Shortcuts") {
                LabeledContent(HotKeyAction.toggleHiddenItems.title) {
                    Text(preferences.shortcut(for: .toggleHiddenItems)?.displayString ?? "—")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent(HotKeyAction.searchMenuBarItems.title) {
                    Text(preferences.shortcut(for: .searchMenuBarItems)?.displayString ?? "—")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("Both can be rebound in the Shortcuts tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var tintColor: Binding<Color> {
        Binding(
            get: { Color(hex: preferences.menuBarTintColor, fallback: .blue) },
            set: { newValue in
                preferences.menuBarTintColor = newValue.hexString
                environment.menuBarAppearance.update()
            }
        )
    }

    private var spacingBinding: Binding<Double> {
        Binding(get: { Double(spacing) }, set: { spacing = Int($0) })
    }

    private var paddingBinding: Binding<Double> {
        Binding(get: { Double(selectionPadding) }, set: { selectionPadding = Int($0) })
    }
}
