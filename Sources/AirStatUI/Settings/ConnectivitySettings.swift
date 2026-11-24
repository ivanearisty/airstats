import SwiftUI
import AirStatKit

/// What the internet check will do, in one sentence, for the line under its address.
///
/// Said back rather than left to be inferred, because one field takes two kinds of
/// address and the user should not have to know the rule to know which one they typed.
enum ConnectivityDescription {
    static func of(_ target: ConnectivityTarget, updateInterval: TimeInterval) -> String {
        let when = "but only while the menu bar readout, the open panel or the expanded widget can show the answer."
        switch target {
        case .ping(let address):
            let every = SettingsLabels.interval(ConnectivityTarget.pingInterval(updateInterval: updateInterval))
            let sentence = "Pings \(address) every \(every), \(when)"
            // The router answers just as well with the line behind it dead.
            guard target.isLocalNetwork else { return sentence }
            return sentence + " That address is on your own network, so the light shows "
                + "whether it answers, not whether the internet does."
        case .https(let url):
            let every = SettingsLabels.interval(ConnectivityTarget.httpsInterval(updateInterval: updateInterval))
            return "Asks \(url.absoluteString) over HTTPS every \(every), \(when)"
        }
    }

    /// The same, from the stored text, which may be something a hand edit broke.
    static func of(text: String, updateInterval: TimeInterval) -> Result<String, ConnectivityTargetError> {
        ConnectivityTarget.parse(text).map { of($0, updateInterval: updateInterval) }
    }
}

/// The address the internet check asks.
///
/// Applied on commit rather than per keystroke, like the hex colour field: "1.1" is a
/// valid prefix of an address and a useless one to ping, and each applied change starts
/// the check over. An entry that does not parse snaps back to what is actually set, with
/// the reason it was refused said underneath, so it never sits there looking applied.
struct ConnectivityTargetField: View {
    let settings: SettingsStore

    @State private var draft = ""
    @State private var refusal: String?
    @FocusState private var isFocused: Bool

    private var stored: String { settings.settings.general.connectivityTarget }

    var body: some View {
        TextField("Check against", text: $draft, prompt: Text(ConnectivityTarget.defaultText))
            .font(.body.monospaced())
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onAppear { draft = stored }
            .onChange(of: stored) { _, new in
                // Changed under the field (Restore Defaults, an import): a refusal about an
                // address that is no longer the one set would be about nothing.
                refusal = nil
                // Never while the field has the insertion point: rewriting the text a
                // user is halfway through typing is how a field eats keystrokes.
                guard !isFocused else { return }
                draft = new
            }
            // Neither turning the check on nor closing the window takes the focus from
            // the field first, so without these an address typed and never submitted
            // would be dropped, and the check would ping the old one (measured in review:
            // the first push after turning it on carried the default address).
            .onChange(of: settings.settings.general.checksConnectivity) { _, _ in commit() }
            .onDisappear(perform: commit)
            .accessibilityLabel("Internet check address")
            .accessibilityHint("An IPv4 address to ping, or an https:// address")

        if let refusal {
            SettingsCaution(refusal)
        } else {
            switch ConnectivityDescription.of(text: stored,
                                              updateInterval: settings.settings.general.updateInterval) {
            // With the toggle off the line says what turning it on would do, so it never
            // reads as something already happening.
            case .success(let description):
                SettingsFootnote(settings.settings.general.checksConnectivity
                                 ? description
                                 : "When on, it " + description.prefix(1).lowercased() + description.dropFirst())
            // Only a hand-edited settings file gets here: the field never stores an
            // address that does not parse.
            case .failure(let error): SettingsCaution(error.message)
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != stored else {
            draft = stored
            return
        }
        switch ConnectivityTarget.parse(trimmed) {
        case .success:
            refusal = nil
            draft = trimmed
            settings.update { $0.general.connectivityTarget = trimmed }
        case .failure(let error):
            refusal = trimmed.isEmpty
                ? error.message
                : "Kept \(stored). \(error.message)"
            draft = stored
        }
    }
}

/// Said under the menu bar's readout list when an Internet Connection readout is on it
/// and cannot work: the check is off, its address cannot be used, or macOS refused the
/// socket. The readout depends on a setting in another pane, so this is where that
/// dependency is made visible, with the one control that fixes the common case.
///
/// Not the Unavailable badge the other readouts use: that says "not available on this
/// Mac", which is untrue of a check that is merely switched off.
struct ConnectivityReadoutNote: View {
    let settings: SettingsStore
    let snapshot: SystemSnapshot

    var body: some View {
        let general = settings.settings.general
        if !general.checksConnectivity {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
                SettingsFootnote(offText(target: general.connectivityTarget))
                Button("Turn On") {
                    settings.update { $0.general.checksConnectivity = true }
                }
                .accessibilityHint("Turns on the internet check in General settings")
            }
        } else if case .failure(let error) = ConnectivityTarget.parse(general.connectivityTarget) {
            SettingsCaution("The internet check cannot use its address. \(error.message) "
                            + "Change it in General settings.")
        } else if let refusal = systemRefusal {
            SettingsCaution(refusal)
        }
    }

    private func offText(target: String) -> String {
        let action: String
        switch ConnectivityTarget.parse(target) {
        case .success(.ping(let address)): action = "pings \(address)"
        case .success(.https(let url)): action = "asks \(url.host ?? url.absoluteString) over HTTPS"
        case .failure: action = "contacts the address in General settings"
        }
        return "Internet Connection needs the internet check, which is off. "
            + "Turned on, it \(action), but only while something on screen can show the answer."
    }

    /// Why the check cannot run when it is on and its address parses: macOS refused the
    /// socket, a filter blocks the ping, or the network has no IPv4 to ping over.
    private var systemRefusal: String? {
        guard let state = snapshot.network.value?.connectivity, !state.isCheckOff,
              let failure = state.failure, failure != .pending else { return nil }
        return failure.message
    }
}
