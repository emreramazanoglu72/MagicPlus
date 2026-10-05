//
//  HardwareSettingsView.swift
//  tabmenu
//

import SwiftUI

/// Settings pane for the battery charge limit and the sensor readout.
struct HardwareSettingsView: View {
    let environment: AppEnvironment

    @Bindable private var preferences: Preferences

    init(environment: AppEnvironment) {
        self.environment = environment
        self.preferences = environment.preferences
    }

    private var chargeLimit: ChargeLimitService { environment.chargeLimit }
    private var installer: HelperInstaller { environment.helperInstaller }

    var body: some View {
        Form {
            Section("Charge limit") {
                if chargeLimit.isSupported {
                    Toggle("Stop charging before the battery is full", isOn: $preferences.isChargeLimitEnabled)
                        .disabled(!installer.state.isInstalled)
                        .onChange(of: preferences.isChargeLimitEnabled) { _, _ in
                            chargeLimit.updateConfiguration()
                        }

                    LabeledContent("Hold at") {
                        HStack {
                            Slider(value: targetBinding, in: 50...100, step: 5)
                            Text(Format.percent(Double(preferences.chargeLimitPercentage) / 100))
                                .font(.callout.monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .disabled(!installer.state.isInstalled || !preferences.isChargeLimitEnabled)

                    LabeledContent("Right now") {
                        Text(stateText)
                            .font(.callout)
                            .foregroundStyle(chargeLimit.isHoldingCharge ? .orange : .secondary)
                    }

                    if let failure = chargeLimit.lastFailure {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Label("This Mac does not let software hold its charge level.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Keeping a lithium battery off full is the single thing that slows its ageing most, which is why Apple's own optimised charging parks at 80%. The limit holds only while MagicPlus is running: quitting it, or a crash, puts charging back to normal within half a minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privileged helper") {
                LabeledContent("Status") {
                    Text(helperStateText)
                        .font(.callout)
                        .foregroundStyle(installer.state.isInstalled ? .green : .secondary)
                }

                HStack {
                    switch installer.state {
                    case .notInstalled, .unavailable:
                        Button("Install Helper…") {
                            installer.install()
                            chargeLimit.updateConfiguration()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    case .requiresApproval:
                        Button("Open Login Items") { installer.openLoginItemsSettings() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Check Again") {
                            installer.refreshState()
                            chargeLimit.updateConfiguration()
                        }
                        .controlSize(.small)
                    case .installed:
                        Button("Remove Helper") {
                            preferences.isChargeLimitEnabled = false
                            chargeLimit.updateConfiguration()
                            installer.remove()
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                }

                if case .unavailable(let message) = installer.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Only root may tell the charging circuit anything, so this one small background process does that and nothing else: it accepts a fixed list of requests from MagicPlus alone, verified by code signature, and undoes every change it has made if the app stops answering. Removing it here leaves nothing behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sensors") {
                LabeledContent("Temperature sensors") {
                    Text(environment.hardware.sensors.isAvailable ? "\(environment.hardware.sensors.sensors.count)" : "—")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Fans") {
                    Text("\(environment.hardware.sensors.fans.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Read straight from the SMC, which every Mac has and no Mac documents. Sensor keys differ from model to model, so what is found here is what this machine reports — and reading them changes nothing. The Stats tab shows the hottest reading in each group; Settings → General can put the CPU temperature in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            installer.refreshState()
            environment.hardware.setMode(.detailed)
        }
        .onDisappear {
            environment.updateMonitorMode(isPopoverOpen: false)
        }
    }

    private var targetBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.chargeLimitPercentage) },
            set: { newValue in
                preferences.chargeLimitPercentage = Int(newValue)
                chargeLimit.updateConfiguration()
            }
        )
    }

    private var stateText: String {
        guard installer.state.isInstalled else {
            return String(localized: "Needs the helper", comment: "Charge limit state")
        }
        guard preferences.isChargeLimitEnabled else {
            return String(localized: "Off", comment: "Charge limit state")
        }
        return chargeLimit.isHoldingCharge
            ? String(localized: "Charging paused", comment: "Charge limit state")
            : String(localized: "Charging allowed", comment: "Charge limit state")
    }

    private var helperStateText: String {
        switch installer.state {
        case .notInstalled: String(localized: "Not installed", comment: "Helper state")
        case .requiresApproval: String(localized: "Waiting for your approval", comment: "Helper state")
        case .installed: String(localized: "Installed", comment: "Helper state")
        case .unavailable: String(localized: "Unavailable in this build", comment: "Helper state")
        }
    }
}
