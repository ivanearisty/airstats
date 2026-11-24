import Testing
import Foundation
@testable import AirStatKit

/// The decisions the light makes, against a scripted transport and a clock the test
/// moves by hand. Every timeline here is the one `SamplingCore` produces at the default
/// two-second interval unless a test says otherwise.
@Suite("Connectivity probe")
struct ConnectivityProbeTests {

    /// Answers when told to, and records what it was asked.
    final class ScriptedTransport: ConnectivityTransport {
        var sent: [UInt16] = []
        var inbox: [ConnectivityEvent] = []
        var sendResult: ConnectivitySend = .sent
        var attempts = 0
        var resets = 0
        var closes = 0
        /// Requests sent before the last reset.
        private var forgotten: Set<UInt16> = []

        func send(sequence: UInt16) -> ConnectivitySend {
            attempts += 1
            if sendResult == .sent { sent.append(sequence) }
            return sendResult
        }

        func collect(_ body: (ConnectivityEvent) -> Void) {
            let events = inbox
            inbox.removeAll()
            for event in events {
                switch event {
                case .answered(let sequence, _), .failed(let sequence, _), .refused(let sequence, _):
                    if !forgotten.contains(sequence) { body(event) }
                }
            }
        }

        /// The real transports forget their requests on a reset, so an answer already
        /// on its way is never reported, and neither is one that turns up later.
        func reset() {
            resets += 1
            inbox.removeAll()
            forgotten.formUnion(sent)
        }

        func close() { closes += 1 }

        func answerLast(latency: TimeInterval? = 0.009) {
            inbox.append(.answered(sequence: sent.last!, latency: latency))
        }
    }

    final class Harness {
        var transports: [ScriptedTransport] = []
        var factoryResult: ConnectivityFailure?
        var now = ContinuousClock.now
        let probe: ConnectivityProbe

        init(_ check: ConnectivityCheck = .active(.ping("1.1.1.1")), firstSequence: UInt16 = 100) {
            var made: (ConnectivityTarget) -> Result<ConnectivityTransport, ConnectivityFailure> = { _ in
                .failure(ConnectivityFailure("unset"))
            }
            probe = ConnectivityProbe(makeTransport: { made($0) }, firstSequence: firstSequence)
            made = { [unowned self] _ in
                if let failure = self.factoryResult { return .failure(failure) }
                let transport = ScriptedTransport()
                self.transports.append(transport)
                return .success(transport)
            }
            probe.configure(check)
        }

        var transport: ScriptedTransport { transports.last! }
        var state: MetricState<ConnectivityReading> { probe.currentState }
        var reading: ConnectivityReading? { state.value }

        func tick(_ seconds: Double = 2, path: ConnectivityPath = .home,
                  resuming: Bool = false, lowPower: Bool = false) {
            now = now.advanced(by: .milliseconds(Int(seconds * 1000)))
            probe.advance(path: path, now: now, isResuming: resuming, isLowPower: lowPower)
        }

        /// Brings the light to a settled green: one request out, answered.
        func settleOnline() {
            tick()
            transport.answerLast()
            tick()
        }
    }

    // MARK: Gating

    @Test("nothing is made or sent while the check is off")
    func offSendsNothing() {
        let harness = Harness(.off)
        for _ in 0..<10 { harness.tick() }
        #expect(harness.transports.isEmpty)
        #expect(harness.state.isCheckOff)
        // Off is something the user can turn on, not something this Mac lacks: Settings
        // greys out a readout whose source is unsupported, and this one is not.
        #expect(!harness.state.isPermanentlyUnavailable)
        #expect(harness.state.failure?.message == ConnectivityProbe.offMessage)
    }

    @Test("nothing is sent while the check is on but nothing on screen shows it")
    func idleSendsNothing() {
        let harness = Harness(.idle)
        for _ in 0..<10 { harness.tick() }
        #expect(harness.transports.isEmpty)
        #expect(harness.state.failure == .pending)
    }

    @Test("an address that cannot be checked is reported, and never sent to")
    func invalidSendsNothing() {
        let harness = Harness(.invalid("That is not an IPv4 address or an https:// address."))
        for _ in 0..<10 { harness.tick() }
        #expect(harness.transports.isEmpty)
        #expect(harness.state.failure == .failed("That is not an IPv4 address or an https:// address."))
    }

    // MARK: The light

    @Test("the first sample sends one request and reads as checking, not as an answer")
    func firstSampleIsChecking() {
        let harness = Harness()
        harness.tick()
        #expect(harness.transports.count == 1)
        #expect(harness.transport.sent.count == 1)
        #expect(harness.state.failure == .pending)
    }

    @Test("an answer turns it green with the latency the transport measured")
    func answerIsGreen() {
        let harness = Harness()
        harness.tick()
        harness.transport.answerLast(latency: 0.0123)
        harness.tick()
        #expect(harness.reading == ConnectivityReading(status: .online, latency: 0.0123,
                                                       target: .ping("1.1.1.1")))
        // Ping goes every sample: the answer's sample sent the next request.
        #expect(harness.transport.sent.count == 2)
    }

    @Test("an answer without a usable timestamp is green with no latency, not zero")
    func unmeasuredLatencyIsNil() {
        let harness = Harness()
        harness.tick()
        harness.transport.answerLast(latency: nil)
        harness.tick()
        #expect(harness.reading?.isOnline == true)
        #expect(harness.reading?.latency == nil)
    }

    @Test("one lost reply leaves green green; the second in a row turns it red, four seconds after the last answer")
    func twoMissesTurnItRed() {
        let harness = Harness()
        harness.settleOnline()                 // t=4: answered, request A out
        harness.tick()                         // t=6: A is 2 s old, one miss
        #expect(harness.reading?.isOnline == true)
        harness.tick()                         // t=8: B is 2 s old, two misses
        #expect(harness.reading?.status == .offline)
        #expect(harness.reading?.detail == "No reply from 1.1.1.1")
        #expect(harness.reading?.latency == nil)
    }

    @Test("a miss between answers never shows")
    func isolatedMissesAreAbsorbed() {
        let harness = Harness()
        harness.settleOnline()
        for _ in 0..<20 {
            harness.tick()                     // the request out is not answered: a miss
            #expect(harness.reading?.isOnline == true)
            harness.transport.answerLast()
            harness.tick()                     // the next one is
            #expect(harness.reading?.isOnline == true)
        }
    }

    @Test("a reply that arrives after its window still counts when it comes")
    func lateReplyRecovers() {
        let harness = Harness()
        harness.settleOnline()
        let late = harness.transport.sent.last!
        harness.tick()
        harness.tick()
        #expect(harness.reading?.status == .offline)
        harness.transport.inbox.append(.answered(sequence: late, latency: 3.9))
        harness.tick()
        #expect(harness.reading == ConnectivityReading(status: .online, latency: 3.9,
                                                       target: .ping("1.1.1.1")))
    }

    /// A saturated upload behind a cheap router can push every round trip past two
    /// seconds. The link is slow, not down, and must not flicker red.
    @Test("a link whose every reply takes longer than the window stays green")
    func slowLinkStaysGreen() {
        let harness = Harness()
        harness.tick()
        harness.tick()
        for _ in 0..<30 {
            // The reply to the request sent two samples ago arrives now.
            let sent = harness.transport.sent
            harness.transport.inbox.append(.answered(sequence: sent[sent.count - 2], latency: 2.6))
            harness.tick()
            #expect(harness.reading?.isOnline == true)
            #expect(harness.reading?.latency == 2.6)
        }
    }

    @Test("with no route out it is red at once, and nothing is sent")
    func noRouteIsImmediate() {
        let harness = Harness()
        harness.settleOnline()
        let sentBefore = harness.transport.sent.count
        harness.tick(path: .none)
        #expect(harness.reading?.status == .offline)
        #expect(harness.reading?.detail == ConnectivityProbe.noRouteDetail)
        for _ in 0..<5 { harness.tick(path: .none) }
        #expect(harness.transport.sent.count == sentBefore)
    }

    @Test("starting with no route makes nothing at all")
    func noRouteFromTheStart() {
        let harness = Harness()
        harness.tick(path: .none)
        #expect(harness.reading?.status == .offline)
        #expect(harness.transports.isEmpty)
    }

    @Test("a new network goes back to checking, asks at once, and ignores answers from the old one")
    func networkChangeStartsOver() {
        let harness = Harness()
        harness.settleOnline()
        let fromOldNetwork = harness.transport.sent.last!
        let resets = harness.transport.resets
        harness.tick(path: .office)
        #expect(harness.state.failure == .pending)
        #expect(harness.transport.resets == resets + 1)
        #expect(harness.transport.sent.last != fromOldNetwork)
        harness.transport.inbox.append(.answered(sequence: fromOldNetwork, latency: 0.01))
        harness.tick(path: .office)
        #expect(harness.state.failure == .pending)
    }

    @Test("a network that changes on every sample still gets no more than the floor allows")
    func flappingPathRespectsTheFloor() {
        let harness = Harness()
        let paths: [ConnectivityPath] = [.home, .office]
        for index in 0..<40 { harness.tick(1, path: paths[index % 2]) }
        // Forty one-second samples, each a new network: twenty sends at most.
        #expect(harness.transport.sent.count <= 20)
    }

    @Test("coming back from sleep goes back to checking rather than showing the last answer")
    func resumeStartsOver() {
        let harness = Harness()
        harness.settleOnline()
        harness.tick(3_600, resuming: true)
        #expect(harness.state.failure == .pending)
        harness.transport.answerLast()
        harness.tick()
        #expect(harness.reading?.isOnline == true)
    }

    @Test("the network coming back after no route goes through checking, not straight to green")
    func routeReturnsThroughChecking() {
        let harness = Harness()
        harness.settleOnline()
        harness.tick(path: .none)
        harness.tick()
        #expect(harness.state.failure == .pending)
    }

    // MARK: Cadence

    @Test("Low Power Mode spaces requests ten seconds apart, and follows up a miss at once")
    func lowPowerCadence() {
        let harness = Harness()
        harness.tick(lowPower: true)                  // t=2: first request
        harness.transport.answerLast()
        for _ in 0..<4 { harness.tick(lowPower: true) }   // t=4…10: green, 8 s since the send
        #expect(harness.transport.sent.count == 1)
        harness.tick(lowPower: true)                  // t=12: 10 s since the send
        #expect(harness.transport.sent.count == 2)
        harness.tick(lowPower: true)                  // t=14: unanswered, one miss
        #expect(harness.transport.sent.count == 4, "a miss is followed up at once, with a pair")
        #expect(harness.reading?.isOnline == true)
    }

    @Test("HTTPS asks about every ten seconds while green")
    func httpsCadence() {
        let harness = Harness(.active(.https(URL(string: "https://example.com")!)))
        for _ in 0..<30 {
            harness.tick()
            if !harness.transport.sent.isEmpty { harness.transport.answerLast(latency: 0.08) }
        }
        // Sixty seconds: one request per ten, give or take the sample it lands on.
        #expect((5...7).contains(harness.transport.sent.count), "\(harness.transport.sent.count)")
        #expect(harness.reading?.isOnline == true)
    }

    @Test("an HTTPS failure counts as a miss and its reason is the detail")
    func httpsFailureIsAMiss() {
        // Samples five seconds apart, since HTTPS is asked again no sooner than its own
        // timeout while the answer is in doubt.
        let harness = Harness(.active(.https(URL(string: "https://example.com")!)))
        harness.tick(5)
        harness.transport.inbox.append(.failed(sequence: harness.transport.sent.last!,
                                               reason: "Couldn't reach example.com"))
        harness.tick(5)
        #expect(harness.state.failure == .pending)
        // The real transport turns the second of the confirming pair away while the first
        // is in flight; this double does not, so it counts both.
        #expect(harness.transport.sent.count >= 2, "the miss is followed up once the spacing allows")
        harness.transport.inbox.append(.failed(sequence: harness.transport.sent.last!,
                                               reason: "Couldn't reach example.com"))
        harness.tick(5)
        #expect(harness.reading?.status == .offline)
        #expect(harness.reading?.detail == "Couldn't reach example.com")
    }

    @Test("an HTTPS request that never completes is abandoned, so the light can still go red")
    func hungRequestIsAbandoned() {
        let harness = Harness(.active(.https(URL(string: "https://example.com")!)))
        harness.tick()
        harness.transport.sendResult = .busy       // the request never comes back
        for _ in 0..<4 { harness.tick() }          // t=10: past the six-second window
        #expect(harness.transport.resets >= 1)
        harness.transport.sendResult = .sent
        for _ in 0..<5 { harness.tick() }
        #expect(harness.reading?.status == .offline)
    }

    @Test("a request with no way out counts as a miss, and says why")
    func refusedSendIsAMiss() {
        let harness = Harness()
        harness.tick()
        harness.transport.sendResult = .failed("no route to 1.1.1.1")
        harness.tick()
        harness.tick()
        #expect(harness.reading?.status == .offline)
        #expect(harness.reading?.detail == "no route to 1.1.1.1")
    }

    /// Mirrors the public IP lookup's "measured in many minutes" test: the whole case for
    /// pinging this often is that it is capped, and an edit that lifts the cap should
    /// fail here rather than ship.
    @Test("never more than one request every 1.5 seconds, however fast the samples come")
    func rateIsCapped() {
        let harness = Harness()
        var sendTimes: [Double] = []
        var clock = 0.0
        for index in 0..<240 {
            // Half-second samples, with a burst of forced ones (a panel opening) mixed in.
            let step = index % 10 == 0 ? 0.05 : 0.5
            clock += step
            let before = harness.transports.last?.sent.count ?? 0
            harness.tick(step)
            if index % 3 == 0, !harness.transport.sent.isEmpty { harness.transport.answerLast() }
            for _ in before..<harness.transport.sent.count { sendTimes.append(clock) }
        }
        #expect(ConnectivityProbe.minimumSpacing == 1.5)
        // The confirming pair is the one place two requests share a sample; apart from
        // it, consecutive samples that sent are at least the floor apart.
        let distinct = Array(Set(sendTimes)).sorted()
        for (earlier, later) in zip(distinct, distinct.dropFirst()) {
            #expect(later - earlier >= 1.5 - 1e-9, "\(earlier) → \(later)")
        }
        #expect(sendTimes.count <= Int(clock / 1.5) * 2 + 2)
    }

    /// The sampling timer's leeway can land two-second samples exactly 1.5 s apart, and
    /// the floor and the reply window are both 1.5 s so that such a sample still sends
    /// and still judges.
    @Test("a sample exactly at the floor sends, and judges a request exactly at its window")
    func floorAndWindowShareTheirBoundary() {
        let harness = Harness()
        harness.tick(1.5)                          // A out
        harness.transport.answerLast()
        harness.tick(1.5)                          // A answered, and B goes out 1.5 s after it
        #expect(harness.transport.sent.count == 2)
        harness.tick(1.5)                          // B is 1.5 s old: a miss, and the pair goes out
        #expect(harness.transport.sent.count == 4)
    }

    @Test("a blocked ping is retried no faster than the floor")
    func blockedRetriesRespectTheFloor() {
        let harness = Harness()
        harness.tick(0.5)
        harness.transport.sendResult = .refused("Something on this Mac blocked the ping to 1.1.1.1")
        let before = harness.transport.attempts
        for _ in 0..<12 { harness.tick(0.5) }      // six seconds of half-second samples
        #expect(harness.transport.attempts - before <= 4)
    }

    @Test("a miss on the old network is not carried over to the new one")
    func missesDoNotCrossNetworks() {
        let harness = Harness()
        harness.settleOnline()                     // t=4: A out
        harness.tick()                             // t=6: A missed, the pair goes out
        let before = harness.transport.sent.count
        harness.tick(path: .office)                // a new network: one request, not a pair
        #expect(harness.transport.sent.count == before + 1)
        harness.tick(path: .office)                // that one request lost: weather, not red
        #expect(harness.state.failure == .pending)
    }

    @Test("each network without IPv4 gets the grace afresh")
    func ipv4GraceStartsOverOnEachNetwork() {
        let harness = Harness()
        let ipv6Only = ConnectivityPath(interface: "en0", ipv4: nil)
        for _ in 0..<6 { harness.tick(path: ipv6Only) }     // past the grace
        #expect(harness.state.failure == .failed(ConnectivityProbe.noIPv4Detail))
        harness.tick(path: .home)                           // the lease arrives
        harness.tick(path: ipv6Only)                        // a later network without IPv4
        #expect(harness.state.failure == .pending)
    }

    @Test("why the old network failed is not given as why the new one is offline")
    func failureReasonDoesNotCrossNetworks() {
        let harness = Harness()
        harness.tick()                                      // A out
        harness.transport.sendResult = .failed("No route to 1.1.1.1")
        harness.tick()                                      // A missed, and the follow-up cannot leave
        #expect(harness.reading?.detail == "No route to 1.1.1.1")
        harness.transport.sendResult = .sent
        for _ in 0..<3 { harness.tick(path: .office) }      // a new network that never answers
        #expect(harness.reading?.status == .offline)
        #expect(harness.reading?.detail == "No reply from 1.1.1.1")
    }

    @Test("once an answer comes back, an earlier failure is no longer the reason")
    func answerClearsTheOldReason() {
        let harness = Harness()
        harness.tick()                                      // A out
        harness.transport.sendResult = .failed("No route to 1.1.1.1")
        harness.tick()                                      // red: no route
        harness.transport.sendResult = .sent
        harness.tick()                                      // B out
        harness.transport.answerLast()
        harness.tick()                                      // green again
        #expect(harness.reading?.isOnline == true)
        harness.tick()
        harness.tick()                                      // two plain misses
        #expect(harness.reading?.detail == "No reply from 1.1.1.1")
    }

    @Test("a lost reply and one lost confirmation leave it green; losing both of the pair turns it red")
    func confirmingPair() {
        let harness = Harness()
        harness.settleOnline()                 // t=4: request A out
        harness.tick()                         // t=6: A unanswered, one miss, pair B and C out
        #expect(harness.transport.sent.count == 4)
        let pair = harness.transport.sent.suffix(2)
        harness.transport.inbox.append(.answered(sequence: pair.last!, latency: 0.01))
        harness.tick()                         // t=8: C answered, B lost
        #expect(harness.reading?.isOnline == true)

        let outage = Harness()
        outage.settleOnline()
        outage.tick()                          // one miss, pair out
        outage.tick()                          // both lost
        #expect(outage.reading?.status == .offline)
    }

    @Test("the unanswered half of a pair is not held against the connection once its twin answers")
    func pairTwinIsNotAMiss() {
        let harness = Harness()
        harness.settleOnline()
        harness.tick()                          // a miss, and the pair goes out
        harness.transport.answerLast()          // one of the pair answers
        harness.tick()
        harness.tick()                          // one further lost request: weather, not red
        #expect(harness.reading?.isOnline == true)
    }

    /// Every request is answered `rtt` after it left, and the answer is read at the first
    /// sample after it lands, as a real socket's queue would hold it. Hand-picked answers
    /// hid this: an earlier version of the slow-link test answered the newest request of
    /// the confirming pair, which settled everything, and never lost a reply.
    @Test("a link slower than the sample interval is never red without a loss, one loss is weather, and Low Power holds")
    func slowLinkIsNotRed() {
        let harness = Harness()
        let rtt = 2.6
        var sentAt: [UInt16: ContinuousClock.Instant] = [:]
        var delivered: Set<UInt16> = []
        var lost: Set<UInt16> = []
        var seen = 0
        func tick(lowPower: Bool = false) {
            let next = harness.now.advanced(by: .seconds(2))
            if let transport = harness.transports.last {
                for (sequence, at) in sentAt.sorted(by: { $0.value < $1.value })
                where !delivered.contains(sequence) && !lost.contains(sequence)
                    && at.advanced(by: .milliseconds(Int(rtt * 1000))) <= next {
                    transport.inbox.append(.answered(sequence: sequence, latency: rtt))
                    delivered.insert(sequence)
                }
            }
            harness.tick(2, lowPower: lowPower)
            if let transport = harness.transports.last {
                for sequence in transport.sent.dropFirst(seen) { sentAt[sequence] = harness.now }
                seen = transport.sent.count
            }
        }
        for _ in 0..<20 {
            tick()
            #expect(harness.reading?.status != .offline, "red with no loss at all")
        }
        let sent = harness.transport.sent
        lost.insert(sent[sent.count - 2])      // the next reply due, and only that one
        tick()
        #expect(harness.reading?.isOnline == true, "one lost reply on a slow link")
        for _ in 0..<5 { tick(lowPower: true) }
        let before = harness.transport.sent.count
        for _ in 0..<30 { tick(lowPower: true) }
        #expect(harness.transport.sent.count - before <= 8, "Low Power's ten seconds on a slow link")
    }

    @Test("a self-assigned 169.254 address is no IPv4 route: checking, then can't check, never red")
    func selfAssignedIsNoIPv4() {
        let harness = Harness()
        let selfAssigned = ConnectivityPath(interface: "en0", ipv4: "169.254.33.7")
        for _ in 0..<6 { harness.tick(path: selfAssigned) }
        #expect(harness.transports.isEmpty)
        #expect(harness.state.failure == .failed(ConnectivityProbe.noIPv4Detail))
    }

    @Test("HTTPS is asked again no sooner than its timeout while the answer is in doubt")
    func httpsRetriesAreSpaced() {
        let harness = Harness(.active(.https(URL(string: "https://example.com")!)))
        for _ in 0..<30 {
            harness.tick()
            if let last = harness.transport.sent.last {
                harness.transport.inbox.append(.failed(sequence: last, reason: "Couldn't reach example.com"))
            }
        }
        // A minute of failures at the default interval: one request per 5 s at most, not
        // one per sample.
        #expect(harness.transport.sent.count <= 13, "\(harness.transport.sent.count)")
        #expect(harness.reading?.status == .offline)
    }

    @Test("a slow link whose answers keep coming is not sent pairs")
    func slowLinkGetsNoPairs() {
        let harness = Harness()
        harness.tick()
        harness.tick()
        for _ in 0..<20 {
            let sent = harness.transport.sent
            let before = sent.count
            harness.transport.inbox.append(.answered(sequence: sent[sent.count - 2], latency: 2.6))
            harness.tick()
            #expect(harness.transport.sent.count == before + 1)
        }
    }

    @Test("a network without IPv4 is checking for a grace, then cannot be checked by ping, and nothing is sent")
    func ipv6OnlyIsNotRed() {
        let harness = Harness()
        let ipv6Only = ConnectivityPath(interface: "en0", ipv4: nil)
        harness.tick(path: ipv6Only)
        #expect(harness.state.failure == .pending)
        for _ in 0..<5 { harness.tick(path: ipv6Only) }    // t=12: ten seconds on
        #expect(harness.state.failure == .failed(ConnectivityProbe.noIPv4Detail))
        #expect(harness.transports.isEmpty)
        // The lease arrives: a new path, checked at once.
        harness.tick(path: .home)
        #expect(harness.transport.sent.count == 1)
        #expect(harness.state.failure == .pending)
    }

    @Test("HTTPS is not held back by a network without IPv4")
    func httpsIgnoresIPv4() {
        let harness = Harness(.active(.https(URL(string: "https://example.com")!)))
        harness.tick(path: ConnectivityPath(interface: "en0", ipv4: nil))
        #expect(harness.transport.sent.count == 1)
    }

    @Test("a ping something on this Mac refuses is 'cannot check', never red")
    func blockedIsNotRed() {
        let harness = Harness()
        harness.tick()
        harness.transport.sendResult = .refused("Something on this Mac blocked the ping to 1.1.1.1")
        for _ in 0..<10 { harness.tick() }
        #expect(harness.reading == nil)
        #expect(harness.state.failure == .failed("Something on this Mac blocked the ping to 1.1.1.1"))
        // Unblocked: answers flow and it goes green.
        harness.transport.sendResult = .sent
        harness.tick()
        harness.transport.answerLast()
        harness.tick()
        #expect(harness.reading?.isOnline == true)
    }

    @Test("a busy transport is not evidence of anything")
    func busyIsNotAMiss() {
        let harness = Harness()
        harness.settleOnline()
        harness.transport.answerLast()
        harness.transport.sendResult = .busy
        for _ in 0..<10 {
            harness.tick()
            #expect(harness.reading?.status != .offline)
        }
    }

    /// A stuck transmit queue answers every send with "no buffer space" for as long as it
    /// lasts. That is not evidence the internet is down, but a green from before it is not
    /// evidence it is up either.
    @Test("a transport that keeps turning requests away stops vouching for the last green")
    func busyStopsVouching() {
        let harness = Harness()
        harness.settleOnline()                  // t=4: answered, request out at t=4
        harness.transport.answerLast()
        harness.transport.sendResult = .busy
        harness.tick()                          // t=6: the answer is read; nothing leaves
        #expect(harness.reading?.isOnline == true)
        for _ in 0..<3 { harness.tick() }       // t=12: 8 s with nothing sent
        #expect(harness.state.failure == .pending)
    }

    @Test("an HTTPS request this Mac keeps in is 'cannot check', never red")
    func httpsRefusalIsNotRed() {
        let harness = Harness(.active(.https(URL(string: "https://nas.local")!)))
        for _ in 0..<6 {
            harness.tick(6)
            if let last = harness.transport.sent.last {
                harness.transport.inbox.append(.refused(sequence: last, reason: "kept in"))
            }
        }
        harness.tick(6)
        #expect(harness.reading == nil)
        #expect(harness.state.failure == .failed("kept in"))
    }

    // MARK: Bookkeeping

    @Test("an answer to a request this probe never sent is ignored")
    func strangersAreIgnored() {
        let harness = Harness()
        harness.tick()
        harness.transport.inbox.append(.answered(sequence: 9_999, latency: 0.001))
        harness.tick()
        #expect(harness.state.failure == .pending)
    }

    @Test("sequence numbers wrap without losing track of the requests")
    func sequenceWraps() {
        let harness = Harness(firstSequence: UInt16.max - 1)
        harness.tick()
        for _ in 0..<4 {
            harness.transport.answerLast()
            harness.tick()
            #expect(harness.reading?.isOnline == true)
        }
        #expect(harness.transport.sent.prefix(4) == [UInt16.max - 1, UInt16.max, 0, 1])
    }

    @Test("requests nobody answers are remembered only so long")
    func outstandingIsBounded() {
        let harness = Harness()
        for _ in 0..<200 { harness.tick() }
        #expect(harness.probe.outstandingCount <= ConnectivityProbe.outstandingLimit)
        #expect(harness.reading?.status == .offline)
    }

    @Test("answers out of order report the newest request's latency")
    func newestAnswerWins() {
        let harness = Harness()
        harness.tick()
        harness.tick()
        let sent = harness.transport.sent
        harness.transport.inbox.append(.answered(sequence: sent[1], latency: 0.020))
        harness.transport.inbox.append(.answered(sequence: sent[0], latency: 2.100))
        harness.tick()
        #expect(harness.reading?.latency == 0.020)
    }

    // MARK: Configuration

    @Test("re-applying the same check changes nothing, however often")
    func sameCheckIsIdempotent() {
        let harness = Harness()
        harness.settleOnline()
        let resets = harness.transport.resets
        for _ in 0..<500 { harness.probe.configure(.active(.ping("1.1.1.1"))) }
        #expect(harness.transport.closes == 0)
        #expect(harness.transport.resets == resets)
        #expect(harness.reading?.isOnline == true)
    }

    @Test("a new address closes the old transport and starts from checking")
    func retargetStartsOver() {
        let harness = Harness()
        harness.settleOnline()
        let old = harness.transport
        harness.probe.configure(.active(.ping("9.9.9.9")))
        #expect(old.closes == 1)
        #expect(harness.state.failure == .pending)
        harness.tick()
        #expect(harness.transports.count == 2)
    }

    @Test("turning the check off forgets the last answer, and turning it on starts from checking")
    func offForgets() {
        let harness = Harness()
        harness.settleOnline()
        harness.probe.configure(.off)
        #expect(harness.state == .checkOff)
        #expect(harness.transport.closes == 1)
        harness.probe.configure(.active(.ping("1.1.1.1")))
        #expect(harness.state.failure == .pending)
    }

    @Test("stopping releases the transport, and the next sample starts over")
    func stopReleases() {
        let harness = Harness()
        harness.settleOnline()
        harness.probe.stop()
        #expect(harness.transport.closes == 1)
        #expect(harness.state.failure == .pending)
        harness.tick(resuming: true)
        #expect(harness.transports.count == 2)
    }

    @Test("a transport the system refuses is reported once and not retried every sample")
    func refusedTransportIsNotHammered() {
        let harness = Harness()
        harness.factoryResult = ConnectivityFailure("macOS would not open a ping socket")
        for _ in 0..<5 { harness.tick() }
        // Not `.unsupported`: that means permanent for this Mac, and this is tried again
        // on the next network.
        #expect(harness.state.failure == .failed("macOS would not open a ping socket"))
        #expect(harness.transports.isEmpty)
        harness.factoryResult = nil
        harness.tick()
        #expect(harness.transports.isEmpty, "nothing changed, so no second attempt")
        harness.tick(path: .office)
        #expect(harness.transports.count == 1, "a new network is worth another try")
    }
}

extension ConnectivityPath {
    static let home = ConnectivityPath(interface: "en0", ipv4: "10.0.0.69")
    static let office = ConnectivityPath(interface: "en0", ipv4: "172.16.4.20")
}
