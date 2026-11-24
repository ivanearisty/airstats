import Foundation

/// Whether the connectivity check should run, decided from settings and from what is on
/// screen, and pushed down to the collector the way the public IP toggle is.
public enum ConnectivityCheck: Sendable, Equatable, Hashable {
    /// The user has not turned the check on. Nothing is ever sent.
    case off
    /// On, but nothing that could show the answer is on screen, so nothing is sent either.
    case idle
    /// On, with an address that cannot be checked.
    case invalid(String)
    case active(ConnectivityTarget)
}

extension MetricState where Value == ConnectivityReading {
    /// The state while the user has the check turned off.
    ///
    /// `.denied`, whose documented meaning is a permission the user has not granted, and
    /// here the permission is to send anything off the machine. It is the one failure
    /// the panel and the widget read as "no row at all", and the render model as "off".
    ///
    /// Every state in which the check is on and cannot run (an address it cannot use, a
    /// network without IPv4, a ping something on this Mac refuses, a socket macOS will
    /// not open) is `.failed`. None of them is `.unsupported`, which means permanent for
    /// this machine: each is tried again on the next network, wake or settings change.
    public static var checkOff: Self { .failure(.denied(ConnectivityProbe.offMessage)) }

    /// True while the check is off: the state in which the panel and the widget leave
    /// the Internet row out instead of showing a check that never runs.
    public var isCheckOff: Bool {
        if case .failure(.denied) = self { return true }
        return false
    }
}

/// The probe's view of the network, taken from the network sample that drives it.
///
/// A change in either field means the Mac is on another network, or on the same one by
/// another route, and nothing known about the old one carries over. The IPv6 address is
/// deliberately not part of it: macOS rotates temporary IPv6 addresses on its own
/// schedule, and the light would drop back to "checking" every time one turned over.
struct ConnectivityPath: Equatable {
    /// The interface behind the default route, or nil when there is none. The same test
    /// the network status dots use, so the two can never disagree about "no network".
    var interface: String?
    var ipv4: String?

    var hasRoute: Bool { interface != nil }

    static let none = ConnectivityPath(interface: nil, ipv4: nil)
}

/// Answers "can this Mac reach the internet right now?" without a timer, a thread or a
/// run-loop source of its own.
///
/// `NetworkCollector` calls `advance` once per network sample, on `SamplingCore`'s queue,
/// so the check runs exactly as often as the network readouts update and stops whenever
/// they stop: asleep, locked, on a sleeping display, paused for Low Power Mode, or with
/// nothing on screen that could show the answer. Each call reads the answers that arrived
/// since the last one, judges the requests that went unanswered, and sends the next
/// request, and none of the three waits for anything.
///
/// Like `PublicIPFetcher` it holds itself to rules the other collectors do not need,
/// because it is one of the two places in the app's own code that send anything anywhere
/// (Sparkle's update check, in its own framework, is the third thing that does): nothing
/// is sent until the user turns it on, nothing is sent while nothing on screen could show
/// the result, and turning it off forgets what it knew.
final class ConnectivityProbe {

    typealias TransportFactory = (ConnectivityTarget) -> Result<ConnectivityTransport, ConnectivityFailure>

    // MARK: Cadence

    /// Never two requests closer together than this, whatever the samples do.
    ///
    /// At the default two-second interval a ping goes out on every network sample, which
    /// costs one `send` and one non-blocking `recvmsg` on a tick that was happening
    /// anyway: no wakeup is added. The floor is what keeps the faster intervals (half a
    /// second, one second) and the extra samples a click forces (panel open, unlock) from
    /// turning that into a ping a second. The hard ceiling is one per 1.5 s, 57,600 a day;
    /// in practice it is 43,200 at the default and at the two faster settings, which
    /// sample the network once a second and so ping on every other sample, and fewer at
    /// the slower ones. 1.5 s rather than 2: a sample is taken once 90% of its interval
    /// has passed, so two-second samples can land 1.8 s apart, and a two-second floor would
    /// skip those and halve the speed of red.
    static let minimumSpacing: TimeInterval = 1.5

    /// In Low Power Mode a working connection is asked every ten seconds instead, and the
    /// cost of noticing a dead one rises from a few seconds to about this long.
    static let lowPowerPingInterval: TimeInterval = 10

    /// HTTPS is the fallback for networks that drop ping, and each request is a real
    /// HEAD to someone's server, so it runs at a sixth of a minute rather than every
    /// sample.
    static let httpsInterval: TimeInterval = ConnectivityTarget.httpsCheckInterval

    /// While an HTTPS answer is in doubt it is asked again after the request's own
    /// timeout rather than on every sample: a server that is down, or a network that is,
    /// gets a HEAD every five seconds, not every two.
    static let httpsRetrySpacing: TimeInterval = HTTPSSession.timeout

    /// How long an echo request has before it counts as a miss. Long enough for any
    /// working path (a geostationary satellite hop is 600 ms), short enough that two
    /// misses in a row read as red within a few seconds. A reply that arrives later
    /// still counts when it comes: see `outstandingLimit`.
    static let pingReplyWindow: TimeInterval = 1.5

    /// The longest the reply window stretches on a link already measured as slow.
    ///
    /// A link whose round trip is longer than the gap between pings (a saturated uplink
    /// behind a cheap router, a congested hotel) would otherwise have every request
    /// counted as a miss before its answer lands, and read red without losing a packet.
    /// So once an answer has been timed, the window is one and a half times that round
    /// trip, up to this. Until one has been timed (after a launch, a wake or a network
    /// change) it is the plain 1.5 s, which a round trip beyond about twice the ping
    /// spacing still outruns once.
    static let slowLinkWindowCap: TimeInterval = 6

    /// The request's own timeout, plus a second for its failure to reach the mailbox.
    static let httpsReplyWindow: TimeInterval = HTTPSSession.timeout + 1

    /// One lost packet is weather; two in a row is an outage. A single miss leaves the
    /// light as it was, and is followed up with a pair rather than one request: red then
    /// takes the first request and both of the pair, so at 1% independent loss a false
    /// red comes about once a month rather than four times a day, and a real outage is
    /// still red at the same sample.
    static let missesBeforeOffline = 2

    /// How long an IPv6 path without IPv4 is given before the check says it cannot ping
    /// over it. Joining a dual-stack network, the IPv6 router advertisement often beats
    /// the DHCPv4 lease by a few seconds, and that window is "checking", not "cannot".
    static let ipv4Grace: TimeInterval = 10

    /// Requests remembered from when they are sent until they are answered. A reply to any of them
    /// still counts, so a link whose replies take three seconds behind a saturated
    /// upload stays green: it is slow, not down. Eight samples is sixteen seconds at the
    /// default interval.
    static let outstandingLimit = 8

    // MARK: Wording

    static let offMessage = "The internet check is off. Turn it on in General settings."
    static let noRouteDetail = "No network connection"
    /// An IPv6-only network (NAT64, as some carriers and offices run) has no route for a
    /// datagram to an IPv4 literal, though the internet may work perfectly. The send
    /// would fail on the spot, and counting that as a miss would paint a working
    /// connection red.
    static let noIPv4Detail = "This network has no IPv4 route to ping over. An https:// address can check it."

    static func noReplyDetail(_ target: ConnectivityTarget) -> String {
        switch target {
        case .ping(let address): return "No reply from \(address)"
        case .https: return "No answer from \(target.hostText)"
        }
    }

    // MARK: State

    private struct Outstanding {
        var sequence: UInt16
        var sentAt: ContinuousClock.Instant
        var isJudged: Bool
    }

    private let makeTransport: TransportFactory
    private var check: ConnectivityCheck = .off
    private var transport: ConnectivityTransport?
    /// Why the transport could not be made. Not retried every sample: a ping socket the
    /// system refused once will be refused again until something changes.
    private var transportFailure: ConnectivityFailure?
    private var state: MetricState<ConnectivityReading> = .checkOff
    private var path: ConnectivityPath?
    private var outstanding: [Outstanding] = []
    private var nextSequence = UInt16.random(in: 0...UInt16.max)
    private var lastSent: ContinuousClock.Instant?
    private var consecutiveMisses = 0
    private var lastFailure: String?
    /// Whether an answer arrived on this sample. A miss with no answer beside it is the
    /// one that earns a confirming pair; on a slow link the late answers keep coming and
    /// a pair would only double the traffic.
    private var answeredThisSample = false
    /// When the current path was first seen without IPv4. Cleared by any path change,
    /// which is what an arriving IPv4 address is.
    private var withoutIPv4Since: ContinuousClock.Instant?
    /// The newest measured round trip. A link that answers slower than the reply window
    /// would otherwise have each request counted as a miss before its answer lands.
    private var recentLatency: TimeInterval?

    init(makeTransport: @escaping TransportFactory = ConnectivityProbe.systemTransport,
         firstSequence: UInt16 = .random(in: 0...UInt16.max)) {
        self.makeTransport = makeTransport
        nextSequence = firstSequence
        outstanding.reserveCapacity(Self.outstandingLimit)
    }

    /// Requests still remembered. For tests: the bound is the point.
    var outstandingCount: Int { outstanding.count }

    static func systemTransport(_ target: ConnectivityTarget) -> Result<ConnectivityTransport, ConnectivityFailure> {
        switch target {
        case .ping(let address): return PingTransport.open(address: address)
        case .https(let url): return .success(HTTPSTransport.open(url: url))
        }
    }

    var currentState: MetricState<ConnectivityReading> { state }

    /// Called on the sampling queue whenever settings or the visible surfaces change.
    /// Settings are re-applied at display rate while a colour picker is dragged, so an
    /// unchanged check must cost nothing and disturb nothing.
    func configure(_ check: ConnectivityCheck) {
        guard check != self.check else { return }
        self.check = check
        closeTransport()
        forget()
        path = nil
        state = Self.restingState(for: check)
    }

    /// Releases the socket or session. The collector calls this when nothing needs the
    /// network any more; the next `advance` starts over from "checking".
    func stop() {
        closeTransport()
        forget()
        path = nil
        state = Self.restingState(for: check)
    }

    private static func restingState(for check: ConnectivityCheck) -> MetricState<ConnectivityReading> {
        switch check {
        case .off: return .checkOff
        // Not `.unsupported`: an address is fixed in a text field, not by another Mac.
        case .invalid(let reason): return .failure(.failed(reason))
        case .idle, .active: return .pending
        }
    }

    /// One step: read what has arrived, judge what has not, send what is due.
    ///
    /// `isResuming` is the sample after a wake, an unlock or a restart. Nothing known
    /// before it can be trusted, and the light goes back to "checking" rather than
    /// showing an answer from before the lid closed.
    func advance(path: ConnectivityPath, now: ContinuousClock.Instant,
                 isResuming: Bool, isLowPower: Bool) {
        guard case .active(let target) = check else { return }

        if isResuming || path != self.path {
            forget()
            transportFailure = nil
            state = .pending
        }
        self.path = path

        // Nothing can leave the machine, so nothing is sent and there is nothing to wait
        // for: this is the one red that needs no probe at all.
        guard path.hasRoute else {
            state = .value(ConnectivityReading(status: .offline, target: target,
                                               detail: Self.noRouteDetail))
            return
        }

        // Nothing is sent that could only fail: this is "cannot check", not "offline",
        // after a grace in which an IPv4 lease may yet arrive.
        if target.method == .ping, path.ipv4 == nil || path.ipv4?.hasPrefix("169.254.") == true {
            let since = withoutIPv4Since ?? now
            withoutIPv4Since = since
            state = Self.seconds(from: since, to: now) < Self.ipv4Grace
                ? .pending : .failure(.failed(Self.noIPv4Detail))
            return
        }

        guard let transport = openTransport(for: target) else { return }
        collect(from: transport, target: target)
        if judge(now: now, target: target), target.method == .https {
            // URLSession promises a completion by its timeout, and the window allows a
            // second more. A request still out past that is abandoned, or the one-in-flight
            // rule would hold every later request back and the light could never go red.
            transport.reset()
        }
        sendIfDue(through: transport, target: target, now: now, isLowPower: isLowPower)
    }

    // MARK: Steps

    private func openTransport(for target: ConnectivityTarget) -> ConnectivityTransport? {
        if let transport { return transport }
        if let transportFailure {
            state = .failure(.failed(transportFailure.message))
            return nil
        }
        switch makeTransport(target) {
        case .success(let made):
            transport = made
            return made
        case .failure(let failure):
            transportFailure = failure
            state = .failure(.failed(failure.message))
            return nil
        }
    }

    private func collect(from transport: ConnectivityTransport, target: ConnectivityTarget) {
        answeredThisSample = false
        var newest: (sentAt: ContinuousClock.Instant, latency: TimeInterval?)?
        transport.collect { event in
            switch event {
            case .answered(let sequence, let latency):
                guard let index = outstanding.firstIndex(where: { $0.sequence == sequence }) else { return }
                let sentAt = outstanding[index].sentAt
                outstanding.remove(at: index)
                // Answers can arrive out of order; the newest request speaks for now.
                if newest.map({ sentAt > $0.sentAt }) ?? true { newest = (sentAt, latency) }
            case .failed(let sequence, let reason):
                guard let index = outstanding.firstIndex(where: { $0.sequence == sequence }) else { return }
                if !outstanding[index].isJudged { consecutiveMisses += 1 }
                outstanding.remove(at: index)
                lastFailure = reason
            case .refused(let sequence, let reason):
                // Kept in by this Mac, so not a miss: the check cannot run, which is not
                // the same as the internet not answering.
                guard let index = outstanding.firstIndex(where: { $0.sequence == sequence }) else { return }
                outstanding.remove(at: index)
                state = .failure(.failed(reason))
            }
        }
        if let newest {
            consecutiveMisses = 0
            lastFailure = nil
            answeredThisSample = true
            if let latency = newest.latency { recentLatency = latency }
            // A request sent no later than one that came back cannot count against the
            // connection when its own answer goes missing: the newer answer already
            // proved the path for that moment. Without this, the unanswered half of a
            // confirming pair would be judged a miss after its twin succeeded.
            for index in outstanding.indices where outstanding[index].sentAt <= newest.sentAt {
                outstanding[index].isJudged = true
            }
            state = .value(ConnectivityReading(status: .online, latency: newest.latency, target: target))
        }
    }

    /// Returns whether any request was newly judged a miss.
    private func judge(now: ContinuousClock.Instant, target: ConnectivityTarget) -> Bool {
        let window = target.method == .ping
            ? max(Self.pingReplyWindow, min((recentLatency ?? 0) * 1.5, Self.slowLinkWindowCap))
            : Self.httpsReplyWindow
        var judged = false
        for index in outstanding.indices where !outstanding[index].isJudged
            && Self.seconds(from: outstanding[index].sentAt, to: now) >= window {
            outstanding[index].isJudged = true
            consecutiveMisses += 1
            judged = true
        }
        markOfflineIfDue(target)
        return judged
    }

    private func sendIfDue(through transport: ConnectivityTransport, target: ConnectivityTarget,
                           now: ContinuousClock.Instant, isLowPower: Bool) {
        let cadence: TimeInterval
        switch target.method {
        case .ping: cadence = isLowPower ? Self.lowPowerPingInterval : Self.minimumSpacing
        case .https: cadence = Self.httpsInterval
        }
        if let lastSent {
            let since = Self.seconds(from: lastSent, to: now)
            let floor = target.method == .https ? Self.httpsRetrySpacing : Self.minimumSpacing
            if since < floor { return }
            // Anything short of a confirmed, unbroken green is followed up as soon as the
            // floor allows: the cadence is for a connection known to work.
            let isSettled = state.value?.isOnline == true && consecutiveMisses == 0
            if isSettled && since < cadence { return }
        }

        // The pair goes out together, the one place two requests share a sample. HTTPS has
        // one in flight at a time, so its second request is simply turned away as busy.
        let count = consecutiveMisses == 1 && !answeredThisSample ? 2 : 1
        for _ in 0..<count {
            guard send(through: transport, target: target, now: now,
                       staleAfter: cadence + Self.slowLinkWindowCap) else { break }
        }
    }

    /// Sends one request. Returns false when another would be pointless this sample.
    private func send(through transport: ConnectivityTransport, target: ConnectivityTarget,
                      now: ContinuousClock.Instant, staleAfter: TimeInterval) -> Bool {
        let sequence = nextSequence
        nextSequence &+= 1
        switch transport.send(sequence: sequence) {
        case .sent:
            if outstanding.count == Self.outstandingLimit { outstanding.removeFirst() }
            outstanding.append(Outstanding(sequence: sequence, sentAt: now, isJudged: false))
            lastSent = now
            return true
        case .busy:
            // A ping the kernel keeps turning away (no buffer space, on an interface whose
            // queue is stuck) is neither an answer nor a miss: red would be wrong under a
            // saturating upload, which fills the same queue. But the last answer ages all
            // the same, and once no request has left for longer than the cadence and the
            // longest reply window together, the light stops vouching for it.
            if state.value?.isOnline == true, let lastSent,
               Self.seconds(from: lastSent, to: now) >= staleAfter {
                state = .pending
            }
            return false
        case .failed(let reason):
            lastSent = now
            lastFailure = reason
            consecutiveMisses += 1
            markOfflineIfDue(target)
            return false
        case .refused(let reason):
            // Nothing left the machine, so nothing about the internet was learned: the
            // check cannot run, which is a different thing from a dead connection.
            lastSent = now
            state = .failure(.failed(reason))
            return false
        }
    }

    private func markOfflineIfDue(_ target: ConnectivityTarget) {
        guard consecutiveMisses >= Self.missesBeforeOffline else { return }
        state = .value(ConnectivityReading(status: .offline, target: target,
                                           detail: lastFailure ?? Self.noReplyDetail(target)))
    }

    /// Everything about requests already sent, except when the last one went: the floor
    /// outlives a reset, or a network that flapped every sample (a VPN in a reconnect
    /// loop) would send on every sample. The transport forgets its side too, so an answer
    /// that arrives later is not mistaken for one to a request sent afterwards.
    private func forget() {
        outstanding.removeAll(keepingCapacity: true)
        consecutiveMisses = 0
        lastFailure = nil
        answeredThisSample = false
        withoutIPv4Since = nil
        recentLatency = nil
        transport?.reset()
    }

    private func closeTransport() {
        transport?.close()
        transport = nil
        transportFailure = nil
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let span = end - start
        return Double(span.components.seconds) + Double(span.components.attoseconds) * 1e-18
    }
}
