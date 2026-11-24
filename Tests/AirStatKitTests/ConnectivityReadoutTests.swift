import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

/// The Internet Connection readout: what each state draws, what it says to VoiceOver,
/// and when the check is allowed to run at all.
@Suite("Internet connection readout")
struct ConnectivityReadoutTests {

    /// One identity for every render, so two renders differ only where the readout does.
    private static let readoutID = UUID()

    private func render(_ snapshot: SystemSnapshot,
                        style: MenuBarDisplayStyle = .statusDot,
                        isOn: Bool = true, isSamplingPaused: Bool = false) -> MenuBarItemRender {
        var settings = Settings()
        settings.general.checksConnectivity = isOn
        settings.menuBar.items = [MenuBarItemConfig(id: Self.readoutID, metric: .connectivity, style: style)]
        return MenuBarRenderModel(snapshot: snapshot, history: MetricHistory(),
                                  settings: settings, isStale: false,
                                  isSamplingPaused: isSamplingPaused).items[0]
    }

    private func snapshot(_ connectivity: MetricState<ConnectivityReading>) -> SystemSnapshot {
        var snapshot = SnapshotFixtures.nominal
        snapshot.network = .value(SnapshotFixtures.network(down: 2_400_000, up: 340_000,
                                                           connectivity: connectivity))
        return snapshot
    }

    private static let offline = ConnectivityReading(status: .offline, target: .ping("1.1.1.1"),
                                                     detail: "No reply from 1.1.1.1")

    // MARK: Styles

    @Test("a new readout lands on the light")
    func lightIsTheDefault() {
        #expect(MenuBarMetric.connectivity.supportedStyles.first == .statusDot)
        let added = MenuBarItemConfig(metric: .connectivity,
                                      style: MenuBarMetric.connectivity.supportedStyles.first!)
        #expect(added.sanitized().style == .statusDot)
    }

    @Test("no graph is offered: there is no series behind a yes-or-no answer")
    func noGraph() {
        #expect(!MenuBarMetric.connectivity.supportedStyles.contains(.graph))
        #expect(!MenuBarMetric.connectivity.supportedStyles.contains(.textAndGraph))
        let clamped = MenuBarItemConfig(metric: .connectivity, style: .graph).sanitized()
        #expect(clamped.style == .statusDot)
    }

    @Test("it needs the network collector and nothing else")
    func requiresNetwork() {
        #expect(MenuBarMetric.connectivity.requiredSource == .network)
    }

    // MARK: The light

    @Test("online is the green light, offline the red one")
    func lights() {
        #expect(render(snapshot(.value(SnapshotFixtures.online(latency: 0.009)))).connectivityLight == .online)
        #expect(render(snapshot(.value(Self.offline))).connectivityLight == .offline)
    }

    @Test("checking is the dim light at the light's width, not the unavailable dash")
    func checkingIsDimNotUnavailable() {
        let item = render(snapshot(.pending))
        #expect(item.connectivityLight == .checking)
        #expect(!item.isUnavailable)
        // A network sample that failed this cycle says nothing about the internet either.
        var failed = SnapshotFixtures.nominal
        failed.network = .failure(.failed("the kernel reported no network interfaces"))
        #expect(render(failed).connectivityLight == .checking)
        #expect(render(SnapshotFixtures.pending).connectivityLight == .checking)
    }

    @Test("off is unavailable, as any readout with nothing to show is, and says it is off")
    func offIsUnavailable() {
        let item = render(snapshot(.checkOff))
        #expect(item.connectivityLight == nil)
        #expect(item.isUnavailable)
        #expect(item.accessibilityLabel == "Internet check off")
        var unsupported = SnapshotFixtures.nominal
        unsupported.network = .failure(.unsupported("no network stack"))
        #expect(render(unsupported).isUnavailable)
        #expect(render(unsupported).accessibilityLabel == "Internet Connection unavailable")
    }

    @Test("switching the check off shows at once, before any sample says so")
    func offIsReadFromSettings() {
        let item = render(snapshot(.value(SnapshotFixtures.online(latency: 0.009))), isOn: false)
        #expect(item.connectivityLight == nil)
        #expect(item.isUnavailable)
        #expect(item.accessibilityLabel == "Internet check off")
    }

    @Test("while sampling is paused the light stops claiming an answer about now")
    func pausedIsChecking() {
        let online = snapshot(.value(SnapshotFixtures.online(latency: 0.009)))
        #expect(render(online, isSamplingPaused: true).connectivityLight == .checking)
        #expect(render(online, isSamplingPaused: true).accessibilityLabel == "Internet check paused")
        #expect(render(online, style: .text, isSamplingPaused: true).primary.valueText == MetricFormatter.unavailable)
        // Nothing else on the bar is touched by the pause: a number is honest about being old.
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        let cpu = MenuBarRenderModel(snapshot: online, history: MetricHistory(), settings: settings,
                                     isStale: false, isSamplingPaused: true).items[0]
        #expect(cpu.primary.valueText == "34%")
    }

    @Test("a check that cannot run is unavailable, with the reason spoken")
    func cannotCheckIsUnavailable() {
        let item = render(snapshot(.failure(.failed(ConnectivityProbe.noIPv4Detail))))
        #expect(item.isUnavailable)
        #expect(item.connectivityLight == nil)
        #expect(item.accessibilityLabel.hasPrefix("Internet check unavailable, this network has no IPv4 route"))
        let refused = render(snapshot(.failure(.unsupported("macOS would not open a ping socket"))))
        #expect(refused.accessibilityLabel == "Internet check unavailable, macOS would not open a ping socket")
    }

    @Test("a reason that starts with an acronym keeps it as written")
    func acronymKeepsItsCapitals() {
        let item = render(snapshot(.failure(.failed("IPv4 is turned off on this Mac"))))
        #expect(item.accessibilityLabel == "Internet check unavailable, IPv4 is turned off on this Mac")
    }

    @Test("no other readout carries the internet light")
    func onlyConnectivityCarriesIt() {
        var settings = Settings()
        settings.general.checksConnectivity = true
        settings.menuBar.items = MenuBarMetric.allCases.map { MenuBarItemConfig(metric: $0) }
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal, history: MetricHistory(),
                                       settings: settings, isStale: false)
        for (config, item) in zip(settings.menuBar.items, model.items) {
            #expect((item.connectivityLight != nil) == (config.metric == .connectivity), "\(config.metric)")
        }
    }

    // MARK: Text and speech

    @Test("the text styles show the latency, or the word")
    func text() {
        #expect(render(snapshot(.value(SnapshotFixtures.online(latency: 0.0094))), style: .text)
                    .primary.valueText == "9 ms")
        #expect(render(snapshot(.value(Self.offline)), style: .text).primary.valueText == "Offline")
        let unmeasured = ConnectivityReading(status: .online, target: .ping("1.1.1.1"))
        #expect(render(snapshot(.value(unmeasured)), style: .text).primary.valueText == "Online")
        #expect(render(snapshot(.pending), style: .text).primary.valueText == MetricFormatter.unavailable)
    }

    /// The status item redraws only when its model changes. A latency in the light's
    /// label would change the model every sample and redraw a dot that looks the same.
    @Test("the light's spoken label carries no latency, so the item does not redraw every sample")
    func lightLabelIsStable() {
        let fast = render(snapshot(.value(SnapshotFixtures.online(latency: 0.009))))
        let slow = render(snapshot(.value(SnapshotFixtures.online(latency: 0.231))))
        #expect(fast == slow)
        #expect(fast.accessibilityLabel == "Internet online")
        let text = render(snapshot(.value(SnapshotFixtures.online(latency: 0.009))), style: .text)
        #expect(text.accessibilityLabel == "Internet online, 9 ms")
    }

    @Test("offline says why, and checking says so")
    func spokenStates() {
        #expect(render(snapshot(.value(Self.offline))).accessibilityLabel
                == "Internet offline, no reply from 1.1.1.1")
        #expect(render(snapshot(.pending)).accessibilityLabel == "Internet connection checking")
    }

    @Test("the reserved width is the widest latency, so a value never moves the bar")
    func widestIsReserved() {
        let formatter = MetricFormatter(settings: GeneralSettings())
        #expect(formatter.widestSample(for: .connectivity) == "999 ms")
        #expect(render(snapshot(.value(SnapshotFixtures.online(latency: 0.009))), style: .text)
                    .primary.widestText == "999 ms")
    }

    /// The status item redraws only when its model changes, so the setting has to be part
    /// of the model or turning it on would change nothing until a reading moved.
    @Test("Differentiate Without Color travels in the model, so turning it on redraws the bar")
    @MainActor
    func differentiateWithoutColorIsInTheModel() {
        var settings = Settings()
        settings.general.checksConnectivity = true
        settings.menuBar.items = [MenuBarItemConfig(id: Self.readoutID, metric: .connectivity)]
        let offline = snapshot(.value(Self.offline))
        let plain = MenuBarRenderModel(snapshot: offline, history: MetricHistory(), settings: settings,
                                       isStale: false)
        let shapes = MenuBarRenderModel(snapshot: offline, history: MetricHistory(), settings: settings,
                                        isStale: false, differentiatesWithoutColor: true)
        #expect(!plain.differentiatesWithoutColor)
        #expect(shapes.differentiatesWithoutColor)
        #expect(plain != shapes)
        #expect(StatusItemController.slice(shapes, readout: Self.readoutID).differentiatesWithoutColor)
    }

    @Test("the caption is PING and the icon is a globe")
    func captionAndSymbol() {
        #expect(MenuBarRenderModel.captionText(for: .connectivity) == "PING")
        #expect(render(snapshot(.pending), style: .iconAndText).symbolName == "globe")
    }
}

@Suite("Latency and the Internet row")
struct ConnectivityFormattingTests {
    private let formatter = MetricFormatter(settings: GeneralSettings())

    @Test("latency is whole milliseconds, then seconds, and never zero")
    func latency() {
        #expect(formatter.latency(0.000_05) == "<1 ms")
        #expect(formatter.latency(0) == "<1 ms")
        #expect(formatter.latency(0.0094) == "9 ms")
        #expect(formatter.latency(0.0095) == "10 ms")
        #expect(formatter.latency(0.9994) == "999 ms")
        #expect(formatter.latency(0.9996) == "1.0 s")
        #expect(formatter.latency(2.46) == "2.5 s")
        #expect(formatter.latency(9.94) == "9.9 s")
        #expect(formatter.latency(12.4) == "12 s")
        for nonsense in [-1, .nan, .infinity, -.infinity] as [Double] {
            #expect(formatter.latency(nonsense) == MetricFormatter.unavailable, "\(nonsense)")
        }
        #expect(formatter.latency(nil) == MetricFormatter.unavailable)
    }

    @Test("a round trip that rounds to one millisecond says so, and one that rounds to ten seconds drops the decimal")
    func latencyUnitEdges() {
        #expect(formatter.latency(0.0012) == "1 ms")
        #expect(formatter.latency(9.96) == "10 s")
    }

    @Test("the row is absent while the check is off, and says each state otherwise")
    func summary() {
        #expect(formatter.connectivitySummary(.checkOff) == nil)
        #expect(formatter.connectivitySummary(.pending) == "Checking…")
        #expect(formatter.connectivitySummary(.value(SnapshotFixtures.online(latency: 0.009)))
                == "Online · 9 ms")
        let offline = ConnectivityReading(status: .offline, target: .ping("1.1.1.1"),
                                          detail: "No reply from 1.1.1.1")
        #expect(formatter.connectivitySummary(.value(offline)) == "Offline · No reply from 1.1.1.1")
        #expect(formatter.connectivitySummary(.value(offline), compact: true) == "Offline")
        // A check that cannot run is not "off": the row stays, and says it could not ask.
        #expect(formatter.connectivitySummary(.failure(.failed("bad address"))) == "Can't check")
        #expect(formatter.connectivitySummary(.failure(.unsupported("no socket"))) == "Can't check")
    }
}

@Suite("When the internet check may run")
struct ConnectivityGatingTests {

    private func settings(on: Bool = true, target: String = "1.1.1.1",
                          readout: Bool = true, readoutEnabled: Bool = true) -> Settings {
        var settings = Settings()
        settings.general.checksConnectivity = on
        settings.general.connectivityTarget = target
        settings.desktopWidget.modules = [.cpu]
        if readout {
            settings.menuBar.items.append(MenuBarItemConfig(metric: .connectivity, style: .statusDot,
                                                            isEnabled: readoutEnabled))
        }
        return settings
    }

    @Test("off by default, on a fresh install")
    func offByDefault() {
        #expect(!Settings().general.checksConnectivity)
        #expect(Settings().connectivityCheck(panelVisible: true, desktopWidgetVisible: true) == .off)
    }

    @Test("off means off, whatever is on screen")
    func offIsOff() {
        let s = settings(on: false)
        #expect(s.connectivityCheck(panelVisible: true, desktopWidgetVisible: true) == .off)
    }

    @Test("on, with the readout in the menu bar, it runs")
    func readoutRunsIt() {
        #expect(settings().connectivityCheck(panelVisible: false, desktopWidgetVisible: false)
                == .active(.ping("1.1.1.1")))
    }

    @Test("on, with nothing on screen showing the answer, it sends nothing")
    func nothingShownIsIdle() {
        #expect(settings(readout: false).connectivityCheck(panelVisible: false, desktopWidgetVisible: false) == .idle)
        #expect(settings(readoutEnabled: false).connectivityCheck(panelVisible: false, desktopWidgetVisible: false) == .idle)
        // The widget on screen, but without its Network module.
        #expect(settings(readout: false).connectivityCheck(panelVisible: false, desktopWidgetVisible: true) == .idle)
    }

    @Test("the open panel and the expanded widget's Network module each run it")
    func panelAndWidgetRunIt() {
        #expect(settings(readout: false).connectivityCheck(panelVisible: true, desktopWidgetVisible: false)
                == .active(.ping("1.1.1.1")))
        var widget = settings(readout: false)
        widget.desktopWidget.modules = [.cpu, .network]
        widget.desktopWidget.isCompact = false
        #expect(widget.connectivityCheck(panelVisible: false, desktopWidgetVisible: true)
                == .active(.ping("1.1.1.1")))
        #expect(widget.connectivityCheck(panelVisible: false, desktopWidgetVisible: false) == .idle)
    }

    /// Compact shows a module's first detail only, and the Internet line is not it.
    @Test("a compact widget does not run it: the Internet line is not on screen")
    func compactWidgetIsIdle() {
        var widget = settings(readout: false)
        widget.desktopWidget.modules = [.network]
        widget.desktopWidget.isCompact = true
        #expect(widget.connectivityCheck(panelVisible: false, desktopWidgetVisible: true) == .idle)
    }

    @Test("a hidden menu bar does not run it, though the readout is still ticked")
    func hiddenMenuBarIsIdle() {
        var hidden = settings()
        hidden.menuBar.isVisible = false
        #expect(hidden.connectivityCheck(panelVisible: false, desktopWidgetVisible: false) == .idle)
    }

    @Test("an address that cannot be used is reported, not quietly replaced")
    func invalidIsReported() {
        if case .invalid(let reason) = settings(target: "http://example.com")
            .connectivityCheck(panelVisible: false, desktopWidgetVisible: false) {
            #expect(reason.contains("https://"))
        } else {
            Issue.record("an http address was accepted")
        }
    }

    @Test("the check pulls in the network collector the same way the readout does")
    func requiredSourcesAgree() {
        let s = settings()
        #expect(s.requiredSources(panelVisible: false, desktopWidgetVisible: false).contains(.network))
    }

    @Test("both new keys survive a round trip, and a file without them gets the defaults")
    func decoding() throws {
        var original = Settings()
        original.general.checksConnectivity = true
        original.general.connectivityTarget = "https://example.com/up"
        original.menuBar.items.append(MenuBarItemConfig(metric: .connectivity, style: .text))
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(original))
        #expect(decoded.general.checksConnectivity)
        #expect(decoded.general.connectivityTarget == "https://example.com/up")
        #expect(decoded.menuBar.items.last?.metric == .connectivity)
        #expect(decoded.menuBar.items.last?.style == .text)

        let old = #"{"general":{"updateInterval":2,"fetchesPublicIP":true}}"#
        let upgraded = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(!upgraded.general.checksConnectivity)
        #expect(upgraded.general.connectivityTarget == ConnectivityTarget.defaultText)
        #expect(upgraded.general.fetchesPublicIP)
    }

    @Test("a malformed value for either key costs that key only")
    func lenientDecoding() throws {
        let broken = #"{"general":{"checksConnectivity":"yes","connectivityTarget":42,"showsPercentSign":false}}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(broken.utf8))
        #expect(!decoded.general.checksConnectivity)
        #expect(decoded.general.connectivityTarget == ConnectivityTarget.defaultText)
        #expect(!decoded.general.showsPercentSign)
    }

    @Test("a hand-edited address that cannot be used still loads, and is reported where it is used")
    func handEditedNonsenseLoads() throws {
        let edited = #"{"general":{"checksConnectivity":true,"connectivityTarget":"not an address"}}"#
        var decoded = try JSONDecoder().decode(Settings.self, from: Data(edited.utf8))
        #expect(decoded.general.connectivityTarget == "not an address")
        decoded.menuBar.items.append(MenuBarItemConfig(metric: .connectivity))
        if case .invalid = decoded.connectivityCheck(panelVisible: false, desktopWidgetVisible: false) {
        } else {
            Issue.record("nonsense was not reported as invalid")
        }
    }
}
