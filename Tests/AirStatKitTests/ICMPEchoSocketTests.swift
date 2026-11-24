import Testing
import Foundation
import Darwin
@testable import AirStatKit

/// The real socket, against the real kernel. The loopback answers echo requests itself,
/// so every test here makes a genuine round trip without needing a network: it holds on
/// a laptop in airplane mode and on a CI runner alike.
@Suite("ICMP echo socket", .serialized)
struct ICMPEchoSocketTests {

    private func open(_ address: String = "127.0.0.1") throws -> ICMPEchoSocket {
        try ICMPEchoSocket.open(address: address).get()
    }

    /// Drains until a reply turns up or `timeout` passes. The probe itself never waits
    /// like this; the test does, because it has no next tick to come back on.
    private func awaitReplies(_ socket: ICMPEchoSocket, timeout: TimeInterval = 1) -> [ICMPEchoSocket.Reply] {
        let deadline = Date().addingTimeInterval(timeout)
        var replies: [ICMPEchoSocket.Reply] = []
        while replies.isEmpty, Date() < deadline {
            socket.drain { replies.append($0) }
            if replies.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        }
        return replies
    }

    @Test("an unprivileged process can open one, and the kernel will timestamp arrivals")
    func opens() throws {
        let socket = try open()
        #expect(socket.isOpen)
        #expect(socket.hasKernelTimestamps)
    }

    @Test("a request to the loopback comes back as our reply, with the kernel's arrival time")
    func roundTrip() throws {
        let socket = try open()
        guard case .sent(let sentAt) = socket.send(sequence: 41) else {
            Issue.record("the loopback refused the request")
            return
        }
        let replies = awaitReplies(socket)
        #expect(replies.map(\.sequence) == [41])
        let stamp = try #require(replies.first?.receivedAt)
        #expect(stamp >= sentAt)
        // A loopback round trip is tens of microseconds; half a second would mean the
        // stamp is the read time or some other clock.
        #expect(ICMPEcho.seconds(fromMachTicks: stamp - sentAt) < 0.5)
    }

    @Test("the arrival time is the kernel's, not the moment the reply was read")
    func stampIsArrivalNotRead() throws {
        let socket = try open()
        guard case .sent(let sentAt) = socket.send(sequence: 7) else {
            Issue.record("the loopback refused the request")
            return
        }
        // The probe reads on the next sample, a second or two after sending.
        Thread.sleep(forTimeInterval: 0.4)
        let replies = awaitReplies(socket)
        let stamp = try #require(replies.first?.receivedAt)
        #expect(ICMPEcho.seconds(fromMachTicks: stamp - sentAt) < 0.2)
    }

    /// Measured on macOS: every datagram ICMP socket receives every echo reply on the
    /// machine. Two of ours stand in for this process and any other.
    @Test("a reply to another socket's request is not reported as ours")
    func foreignRepliesAreFiltered() throws {
        // The identifiers may collide (one chance in 65,536); the token still tells the
        // replies apart, which is the property under test.
        let ours = try open()
        let theirs = try open()
        guard case .sent = theirs.send(sequence: 5) else {
            Issue.record("the loopback refused the request")
            return
        }
        #expect(awaitReplies(theirs).map(\.sequence) == [5])
        var leaked: [ICMPEchoSocket.Reply] = []
        ours.drain { leaked.append($0) }
        #expect(leaked.isEmpty)
    }

    @Test("several requests are told apart by sequence number")
    func sequencesAreDistinct() throws {
        let socket = try open()
        for sequence in [UInt16.max, 0, 1] {
            guard case .sent = socket.send(sequence: sequence) else {
                Issue.record("the loopback refused request \(sequence)")
                return
            }
        }
        var replies: [UInt16] = []
        let deadline = Date().addingTimeInterval(1)
        while replies.count < 3, Date() < deadline {
            socket.drain { replies.append($0.sequence) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(Set(replies) == [UInt16.max, 0, 1])
    }

    @Test("draining an empty socket returns at once")
    func drainDoesNotBlock() throws {
        let socket = try open("127.0.0.2")  // the loopback network, and never answered
        _ = socket.send(sequence: 1)
        let started = Date()
        var replies = 0
        socket.drain { _ in replies += 1 }
        #expect(replies == 0)
        #expect(Date().timeIntervalSince(started) < 0.1)
    }

    @Test("a closed socket sends nothing and reads nothing")
    func closedSocketIsInert() throws {
        let socket = try open()
        socket.close()
        #expect(!socket.isOpen)
        if case .sent = socket.send(sequence: 1) { Issue.record("a closed socket claimed to send") }
        var replies = 0
        socket.drain { _ in replies += 1 }
        #expect(replies == 0)
        socket.close()  // twice is harmless
    }

    /// A firewall or content filter refusing the packet is not the internet failing to
    /// answer, and the light must not go red for it.
    @Test("a send this Mac refuses is blocked, a send with no way out is a dead path, and a full buffer is neither")
    func sendErrorsAreSortedByWhatTheyMean() {
        for code in [EPERM, EACCES] {
            #expect(ICMPEchoSocket.outcome(for: code, address: "1.1.1.1")
                    == .blocked("Something on this Mac blocked the ping to 1.1.1.1"), "\(code)")
        }
        for code in [ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN, EADDRNOTAVAIL] {
            #expect(ICMPEchoSocket.outcome(for: code, address: "1.1.1.1") == .failed("No route to 1.1.1.1"), "\(code)")
        }
        for code in [EAGAIN, ENOBUFS] {
            #expect(ICMPEchoSocket.outcome(for: code, address: "1.1.1.1") == .notSent, "\(code)")
        }
    }

    /// Measured in review: Local Network privacy refuses a ping to a LAN address by
    /// shutting the connected socket, so the send fails with EPIPE, and the SIGPIPE that
    /// came with it killed the whole app (exit 141), on every launch while access stayed
    /// denied. The shut socket also never sends again, not even after access is allowed.
    @Test("a send macOS refuses raises no signal, reads as blocked, and the next goes out on a fresh socket")
    func refusedSendSurvivesAndRecovers() throws {
        let socket = try open()
        socket.shutForSending()
        let refused = socket.send(sequence: 1)
        guard case .blocked = refused else {
            Issue.record("expected blocked, got \(refused)")
            return
        }
        guard case .sent = socket.send(sequence: 2) else {
            Issue.record("the replacement socket did not send")
            return
        }
        #expect(awaitReplies(socket).map(\.sequence) == [2])
    }

    @Test("a refusal of a local address names the setting that lifts it")
    func localRefusalNamesTheSetting() {
        guard case .blocked(let reason) = ICMPEchoSocket.outcome(for: EPIPE, address: "192.168.1.20") else {
            Issue.record("EPIPE was not read as blocked")
            return
        }
        #expect(reason.contains("Local Network"))
        guard case .blocked(let elsewhere) = ICMPEchoSocket.outcome(for: EPIPE, address: "1.1.1.1") else {
            Issue.record("EPIPE was not read as blocked")
            return
        }
        #expect(!elsewhere.contains("Local Network"))
    }

    @Test("an address that is not IPv4 is refused before a socket is made")
    func refusesNonIPv4() {
        if case .success = ICMPEchoSocket.open(address: "example.com") {
            Issue.record("opened a ping socket for a name")
        }
    }

    /// Measured before this was connected: every echo reply on the Mac landed in this
    /// socket's 8 KB buffer, so another app's fast ping cost a read per reply here and
    /// could crowd out our own. Connected, the kernel drops them before queueing.
    @Test("once connected, replies from any other address never reach the socket")
    func connectedSocketFiltersBySource() throws {
        // On the loopback network, so nothing leaves the Mac, and nothing answers it.
        let watched = try open("127.0.0.2")
        guard case .sent = watched.send(sequence: 1) else {
            Issue.record("the loopback refused the request")
            return
        }
        let other = try open()
        guard case .sent = other.send(sequence: 2) else {
            Issue.record("the loopback refused the request")
            return
        }
        #expect(awaitReplies(other).map(\.sequence) == [2])
        watched.drain { _ in Issue.record("a reply from another address was reported") }
        #expect(watched.datagramsRead == 0)
    }
}

/// The whole chain on the real machine: the network collector, the probe it owns, the
/// socket and the kernel. The loopback answers without a network, but the probe also
/// needs a primary interface with IPv4 to consider the path usable, which every CI
/// runner and every connected Mac has.
@Suite("Internet check end to end", .serialized)
struct ConnectivityEndToEndTests {

    @Test("the real collector carries a real, kernel-timed answer one sample after asking")
    func collectorCarriesAnAnswer() throws {
        let collector = NetworkCollector()
        // Straight to the check rather than through the address parser, which refuses the
        // loopback for users because it answers with every cable pulled.
        collector.setConnectivityCheck(.active(.ping("127.0.0.1")))
        collector.start()
        defer { collector.stop() }

        let first = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true,
                                                             activity: .menuBar))
        // The first sample is the rate baseline, so the snapshot itself is pending; the
        // request has gone out on it all the same.
        #expect(first.failure == .pending)
        Thread.sleep(forTimeInterval: 0.25)
        let second = collector.collect(context: SampleContext(elapsed: 0.25, isFirstSample: false,
                                                              activity: .menuBar))
        let network = try #require(second.value)
        guard network.primaryInterfaceName != nil, network.localIPv4 != nil else {
            // Offline, or IPv6 only: the probe rightly declines to ping.
            #expect(network.connectivity.value?.isOnline != true)
            return
        }
        let reading = try #require(network.connectivity.value)
        #expect(reading.isOnline)
        #expect(reading.target == .ping("127.0.0.1"))
        let latency = try #require(reading.latency)
        #expect(latency >= 0 && latency < 0.1)
    }

    /// Sleep suspends sampling without stopping the collector, so the wake reaches it
    /// only as the first sample's flags. Those are what must send the check back to
    /// "checking", or the green from before the lid closed is shown as an answer about now.
    @Test("a wake goes back to checking, though sleep never stopped the collector")
    func wakeStartsOver() throws {
        let collector = NetworkCollector()
        collector.setConnectivityCheck(.active(.ping("127.0.0.1")))
        collector.start()
        defer { collector.stop() }
        _ = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .menuBar))
        Thread.sleep(forTimeInterval: 0.25)
        let before = collector.collect(context: SampleContext(elapsed: 0.25, isFirstSample: false,
                                                              activity: .menuBar))
        // Offline, or IPv6 only: nothing was asked, so there is no answer for a wake to clear.
        guard before.value?.connectivity.value?.isOnline == true else { return }
        // What SamplingCore hands the first sample after a wake.
        _ = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .menuBar,
                                                     didWakeFromSleep: true))
        Thread.sleep(forTimeInterval: 0.25)
        let after = collector.collect(context: SampleContext(elapsed: 0.25, isFirstSample: false,
                                                             activity: .menuBar))
        let network = try #require(after.value)
        #expect(network.connectivity.value == nil, "an answer from before the sleep survived the wake")
    }

    /// 127.0.0.2 is on the loopback network but nothing answers it, so no other test's
    /// socket is connected there and the one found can only be the check's.
    @Test("stopping the collector really closes the check's socket")
    func stopClosesTheSocket() {
        let collector = NetworkCollector()
        collector.setConnectivityCheck(.active(.ping("127.0.0.2")))
        collector.start()
        _ = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .menuBar))
        let opened = Self.socketsConnected(to: "127.0.0.2")
        collector.stop()
        // No IPv4 path here: nothing was sent, so no socket was connected to look for.
        guard opened == 1 else { return }
        #expect(Self.socketsConnected(to: "127.0.0.2") == 0)
    }

    private static func socketsConnected(to address: String) -> Int {
        var target = in_addr()
        guard inet_pton(AF_INET, address, &target) == 1 else { return 0 }
        var count = 0
        for descriptor in 0..<getdtablesize() {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &length) }
            }
            if result == 0, peer.sin_family == sa_family_t(AF_INET), peer.sin_addr.s_addr == target.s_addr {
                count += 1
            }
        }
        return count
    }

    @Test("a restarted collector starts the check from checking, not from the answer before the stop")
    func stopAndRestart() throws {
        let collector = NetworkCollector()
        collector.setConnectivityCheck(.active(.ping("127.0.0.1")))
        collector.start()
        _ = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .menuBar))
        Thread.sleep(forTimeInterval: 0.25)
        let before = collector.collect(context: SampleContext(elapsed: 0.25, isFirstSample: false,
                                                              activity: .menuBar))
        guard before.value?.connectivity.value?.isOnline == true else {
            // Offline or IPv6 only: there is no green to carry over.
            return
        }
        collector.stop()
        collector.start()
        defer { collector.stop() }
        // Every sample here is inside the probe's 1.5 s floor, so no new request goes out
        // and no new answer can come back: anything green is the old answer surviving.
        // The first sample after a start is the rate baseline, so the second is read.
        for elapsed in [0.25, 0.25] {
            Thread.sleep(forTimeInterval: elapsed)
            _ = collector.collect(context: SampleContext(elapsed: elapsed, isFirstSample: false,
                                                         activity: .menuBar))
        }
        Thread.sleep(forTimeInterval: 0.25)
        let after = try #require(collector.collect(context: SampleContext(elapsed: 0.25, isFirstSample: false,
                                                                          activity: .menuBar)).value)
        #expect(after.connectivity.failure == .pending, "an answer survived the stop")
    }
}
