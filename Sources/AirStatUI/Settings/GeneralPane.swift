import SwiftUI
import AppKit
import AirStatKit

struct GeneralPane: View {
    let settings: SettingsStore
    /// Absent in the offscreen renderer, which has no running app to update.
    var updater: SoftwareUpdater?

    /// `LoginItem.synchronize` reports a real failure — a missing bundle, a
    /// revoked approval — and the toggle is worthless if that is swallowed.
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open AirStats at login",
                       isOn: settings.binding(\.general.launchAtLogin, onChange: applyLoginItem))
                if let loginItemError {
                    SettingsCaution(loginItemError)
                }
                Toggle("Show icon in the Dock",
                       isOn: settings.binding(\.general.showsDockIcon, onChange: applyDockIcon))
            } header: {
                Text("Startup")
            }

            Section {
                Picker("Update interval", selection: settings.binding(\.general.updateInterval)) {
                    ForEach(GeneralSettings.allowedIntervals, id: \.self) { interval in
                        Text(SettingsLabels.interval(interval)).tag(interval)
                    }
                }
                Toggle("Slow down when the menu bar is hidden",
                       isOn: settings.binding(\.general.throttlesWhenOccluded))
                Toggle("Pause sampling on Low Power Mode",
                       isOn: settings.binding(\.general.pausesOnLowPower))
            } header: {
                Text("Sampling")
            }

            Section {
                Picker("Temperature", selection: settings.binding(\.general.temperatureUnit)) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker("Network rate", selection: settings.binding(\.general.networkRateUnit)) {
                    ForEach(NetworkRateUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker("Storage sizes", selection: settings.binding(\.general.byteUnitStyle)) {
                    ForEach(ByteUnitStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Show the percent sign", isOn: settings.binding(\.general.showsPercentSign))
            } header: {
                Text("Units")
            }

            // Every update control in one place. The two automatic-update toggles were
            // here and the button that performs a check was in About, so answering
            // "is this up to date, and will it stay that way" meant knowing to look in
            // two panes and finding no cross-reference in either.
            Section {
                // The answer to a check is drawn beside the button rather than in
                // Sparkle's alert. Only an update opens a window, and only when the
                // user asks to install it, because that window carries the release
                // notes and the Install button.
                HStack(spacing: Design.Space.l) {
                    if let pending = updater?.pending {
                        Button(pending.isReadyToInstall ? "Restart" : "Install…") {
                            updater?.installPending()
                        }
                        .accessibilityHint(pending.isReadyToInstall
                                           ? "Relaunches AirStats into the new version"
                                           : "Opens the updater to install it")
                    } else {
                        Button("Check Now") { updater?.checkQuietly() }
                            .disabled(updater?.canCheck != true)
                            .accessibilityHint("Asks airstats.app whether a newer version exists")
                    }
                    Spacer()
                    updateStatus
                }
                // Stored by Sparkle rather than in the settings file, so this reads and
                // writes the updater itself. Only the offscreen renderer has none.
                Toggle("Check for updates automatically", isOn: checksAutomatically)
                    .disabled(updater == nil)
                // Sparkle offers the same choice the first time it installs something,
                // and takes the answer as standing. Without this row the only way back
                // is to wait for another release and refuse it there.
                Toggle("Install updates automatically", isOn: installsAutomatically)
                    .disabled(updater == nil || !(updater?.checksAutomatically ?? false))
            } header: {
                Text("Updates")
            }

            Section {
                Toggle("Look up my public IP address",
                       isOn: settings.binding(\.general.fetchesPublicIP))
                // The other setting that sends something off the machine, so it sits
                // beside the first, off by default, under the same footer.
                Toggle("Check my internet connection",
                       isOn: settings.binding(\.general.checksConnectivity))
                // Shown with the toggle off too, so the address can be chosen before the
                // first request goes to the default one.
                ConnectivityTargetField(settings: settings)
            } header: {
                Text("Privacy")
            } footer: {
                SettingsFootnote("With both off, neither contacts anything, and the Network "
                                 + "module shows your local addresses only.")
            }
        }
        .settingsFormStyle()
    }

    // MARK: Side effects

    private var checksAutomatically: Binding<Bool> {
        Binding(get: { updater?.checksAutomatically ?? true },
                set: { updater?.setChecksAutomatically($0) })
    }

    private var installsAutomatically: Binding<Bool> {
        Binding(get: { updater?.installsAutomatically ?? false },
                set: { updater?.setInstallsAutomatically($0) })
    }

    /// The state of updates, beside the button that changes it. It also answers "is
    /// this thing actually running?": the automatic check is silent when it finds
    /// nothing, so without the checked time a user who never pressed anything would see
    /// no sign of it at all. A failure is named, because Sparkle stamps the check date
    /// on failure too and a feed unreachable for a month would otherwise read as fine.
    @ViewBuilder
    private var updateStatus: some View {
        if updater?.isChecking == true {
            HStack(spacing: Design.Space.s) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
            .foregroundStyle(.secondary)
        } else if let failure = updater?.lastCheckFailure {
            Text("Couldn't check")
                .foregroundStyle(.secondary)
                .help(failure)
                .accessibilityValue(failure)
        } else if updater?.pending != nil || updater?.lastCheck != nil {
            VStack(alignment: .trailing, spacing: Design.Space.xxs) {
                if let pending = updater?.pending {
                    Text(pending.isReadyToInstall ? "AirStats \(pending.version) is ready"
                                                  : "AirStats \(pending.version) is available")
                } else {
                    Text("Up to date")
                }
                if let checked = updater?.lastCheck {
                    Text("Checked \(Self.checkedPhrase(checked))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    /// A check that has just finished is stamped a moment after the `Date()` it is
    /// drawn against, and the formatter reads that as "in 0 seconds".
    private static func checkedPhrase(_ checked: Date) -> String {
        let now = Date()
        guard now.timeIntervalSince(checked) >= 60 else { return "just now" }
        return relative.localizedString(for: checked, relativeTo: now)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Process-level state rather than a stored preference, so the store's value alone
    /// would change nothing until the next launch.
    private func applyDockIcon(_ shows: Bool) {
        NSApp.setActivationPolicy(shows ? .regular : .accessory)
        // Switching policy drops key window status; take it back so the settings
        // window the user is standing in does not slide behind everything.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyLoginItem(_ enabled: Bool) {
        if let error = LoginItem.synchronize(enabled: enabled) {
            loginItemError = "macOS refused to \(enabled ? "register" : "remove") the login item: \(error.localizedDescription)"
            // The stored preference must not claim something the system rejected.
            settings.update { $0.general.launchAtLogin = LoginItem.isEnabled }
        } else {
            loginItemError = nil
        }
    }
}
