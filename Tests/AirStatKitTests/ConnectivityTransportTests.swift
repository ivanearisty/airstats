import Testing
import Foundation
@testable import AirStatKit

/// The HTTPS transport's bookkeeping, driven through a stub fetch so nothing leaves the
/// machine. The real round trip is exercised by `AirStats --probe`; what is guarded here
/// is the part that decides which answers count.
@Suite("HTTPS connectivity transport")
struct HTTPSTransportTests {

    private final class StubFetch: @unchecked Sendable {
        private let lock = NSLock()
        private var completions: [@Sendable (HTTPSOutcome) -> Void] = []
        private(set) var requests = 0
        private(set) var cancels = 0
        private(set) var invalidations = 0

        var fetch: HTTPSFetch {
            { [self] _, completion in
                lock.lock()
                requests += 1
                completions.append(completion)
                lock.unlock()
                return { [self] in
                    lock.lock()
                    cancels += 1
                    lock.unlock()
                }
            }
        }

        var invalidate: () -> Void { { [self] in invalidations += 1 } }

        func answer(_ outcome: HTTPSOutcome) {
            lock.lock()
            let pending = completions
            completions.removeAll()
            lock.unlock()
            for completion in pending { completion(outcome) }
        }
    }

    private let url = URL(string: "https://example.com")!

    private func events(_ transport: ConnectivityTransport) -> [ConnectivityEvent] {
        var events: [ConnectivityEvent] = []
        transport.collect { events.append($0) }
        return events
    }

    @Test("one request at a time: a second send while the first is out is turned away")
    func oneInFlight() {
        let stub = StubFetch()
        let transport = HTTPSTransport(url: url, fetch: stub.fetch)
        #expect(transport.send(sequence: 1) == .sent)
        #expect(transport.send(sequence: 2) == .busy)
        #expect(stub.requests == 1)
        stub.answer(.success(()))
        #expect(transport.send(sequence: 3) == .sent)
        #expect(stub.requests == 2)
    }

    @Test("an answer is held until it is collected, then reported once")
    func answerIsCollectedOnce() {
        let stub = StubFetch()
        let transport = HTTPSTransport(url: url, fetch: stub.fetch)
        _ = transport.send(sequence: 9)
        #expect(events(transport).isEmpty)
        stub.answer(.success(()))
        let first = events(transport)
        #expect(first.count == 1)
        if case .answered(let sequence, let latency) = first.first {
            #expect(sequence == 9)
            #expect((latency ?? -1) >= 0)
        } else {
            Issue.record("expected an answer, got \(first)")
        }
        #expect(events(transport).isEmpty)
    }

    @Test("a failure carries its reason")
    func failureCarriesReason() {
        let stub = StubFetch()
        let transport = HTTPSTransport(url: url, fetch: stub.fetch)
        _ = transport.send(sequence: 4)
        stub.answer(.failure(ConnectivityFailure("couldn't reach example.com: offline")))
        #expect(events(transport) == [.failed(sequence: 4, reason: "couldn't reach example.com: offline")])
    }

    @Test("a request this Mac kept in is reported as a refusal, not a failure")
    func refusalIsItsOwnEvent() {
        let stub = StubFetch()
        let transport = HTTPSTransport(url: url, fetch: stub.fetch)
        _ = transport.send(sequence: 6)
        stub.answer(.failure(ConnectivityFailure("kept in", isRefusal: true)))
        #expect(events(transport) == [.refused(sequence: 6, reason: "kept in")])
    }

    @Test("a cancelled request reports nothing, since the cancelling was ours")
    func cancellationIsSilent() {
        let stub = StubFetch()
        let transport = HTTPSTransport(url: url, fetch: stub.fetch)
        _ = transport.send(sequence: 4)
        stub.answer(nil)
        #expect(events(transport).isEmpty)
        #expect(transport.send(sequence: 5) == .sent)
    }

    @Test("an answer that arrives after a reset is discarded, and a new request can go at once")
    func resetDisownsTheRequestInFlight() {
        let stub = StubFetch()
        let transport = HTTPSTransport(url: url, fetch: stub.fetch)
        _ = transport.send(sequence: 1)
        transport.reset()
        #expect(stub.cancels == 1)
        #expect(transport.send(sequence: 2) == .sent)
        // Both the disowned request and the new one are answered; only the new one counts.
        stub.answer(.success(()))
        let reported = events(transport)
        #expect(reported.count == 1)
        if case .answered(let sequence, _) = reported.first { #expect(sequence == 2) }
    }

    @Test("a request refused on the spot completes before send returns, and is not cancelled")
    func synchronousCompletion() {
        let transport = HTTPSTransport(url: url, fetch: { _, completion in
            completion(.failure(ConnectivityFailure("refused")))
            return { Issue.record("a finished request was cancelled") }
        })
        #expect(transport.send(sequence: 1) == .sent)
        #expect(events(transport) == [.failed(sequence: 1, reason: "refused")])
        #expect(transport.send(sequence: 2) == .sent)
    }

    /// The probe never reuses a sequence number this soon, but the transport cannot know
    /// that: the generation is what disowns the old request, not the number.
    @Test("an answer to a request from before a reset is discarded even when the new request has its number")
    func resetDisownsBySequenceAndGeneration() {
        var completions: [@Sendable (HTTPSOutcome) -> Void] = []
        let transport = HTTPSTransport(url: url, fetch: { _, completion in
            completions.append(completion)
            return {}
        })
        _ = transport.send(sequence: 1)
        transport.reset()
        _ = transport.send(sequence: 1)
        completions[0](.success(()))
        #expect(events(transport).isEmpty)
    }

    @Test("a request that finished before send returned leaves nothing for a reset to cancel")
    func finishedRequestLeavesNoCancelHandle() {
        let transport = HTTPSTransport(url: url, fetch: { _, completion in
            completion(.success(()))
            return { Issue.record("a finished request was cancelled") }
        })
        #expect(transport.send(sequence: 1) == .sent)
        transport.reset()
    }

    @Test("an answer that arrived but was not yet collected is dropped by a reset")
    func resetDropsUncollectedAnswers() {
        let stub = StubFetch()
        let transport = HTTPSTransport(url: url, fetch: stub.fetch)
        _ = transport.send(sequence: 1)
        stub.answer(.success(()))
        transport.reset()
        #expect(events(transport).isEmpty)
    }

    @Test("closing invalidates the session once and refuses further sends")
    func closeIsFinal() {
        let stub = StubFetch()
        let transport = HTTPSTransport(url: url, fetch: stub.fetch, invalidate: stub.invalidate)
        _ = transport.send(sequence: 1)
        transport.close()
        transport.close()
        #expect(stub.invalidations == 1)
        stub.answer(.success(()))
        #expect(events(transport).isEmpty)
        if case .sent = transport.send(sequence: 2) { Issue.record("a closed transport sent") }
    }

    @Test("any response counts, a redirect or a server error included; no response does not")
    func interpretation() {
        let ok = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)
        let moved = HTTPURLResponse(url: url, statusCode: 301, httpVersion: nil, headerFields: nil)
        let broken = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)
        for response in [ok, moved, broken] {
            if case .some(.success) = HTTPSSession.interpret(url: url, response: response, error: nil) {
            } else {
                Issue.record("status \(response?.statusCode ?? -1) did not count")
            }
        }
        // No path while the Mac has a route out is this Mac keeping the request in: Local
        // Network privacy refuses a LAN host so. A refusal, never a miss.
        let refused = HTTPSSession.interpret(url: url, response: nil,
                                             error: URLError(.notConnectedToInternet))
        if case .some(.failure(let failure)) = refused {
            #expect(failure.isRefusal)
            #expect(failure.message.contains("Local Network"))
        } else {
            Issue.record("a refusal counted as an answer")
        }
        if case .some(.failure(let failure)) = HTTPSSession.interpret(url: url, response: nil,
                                                                      error: URLError(.timedOut)) {
            #expect(!failure.isRefusal, "a timeout is the network's doing")
        }
        // A TLS failure is what a captive portal intercepting HTTPS looks like, and the
        // row says so rather than burying it in URLError's prose.
        let portal = HTTPSSession.interpret(url: url, response: nil,
                                            error: URLError(.serverCertificateUntrusted))
        if case .some(.failure(let failure)) = portal {
            #expect(failure.message.contains("login page"))
        } else {
            Issue.record("an untrusted certificate counted")
        }
        let timedOut = HTTPSSession.interpret(url: url, response: nil, error: URLError(.timedOut))
        if case .some(.failure(let failure)) = timedOut {
            #expect(failure.message == "example.com timed out")
        }
        // Not a URLError at all still produces a reason, never a crash or an answer.
        struct Odd: Error {}
        if case .some(.failure(let failure)) = HTTPSSession.interpret(url: url, response: nil, error: Odd()) {
            #expect(failure.message == "Couldn't reach example.com")
        } else {
            Issue.record("a foreign error counted as an answer")
        }
        #expect(HTTPSSession.interpret(url: url, response: nil, error: URLError(.cancelled)) == nil)
        let notHTTP = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        if case .some(.success) = HTTPSSession.interpret(url: url, response: notHTTP, error: nil) {
            Issue.record("a non-HTTP response counted")
        }
    }
}

@Suite("Ping connectivity transport")
struct PingTransportTests {

    @Test("a round trip is measured on the send's own clock, and a stamp from before the send is no measurement")
    func roundTripArithmetic() {
        let second = UInt64(1 / ICMPEcho.seconds(fromMachTicks: 1))
        #expect(abs((PingTransport.roundTrip(sentAt: 1_000, receivedAt: 1_000 + second / 100) ?? 0) - 0.01) < 0.000_1)
        #expect(PingTransport.roundTrip(sentAt: 1_000, receivedAt: 1_000) == 0)
        // A foreign reply stamped before our send (measured: the first experiment trapped
        // on exactly this subtraction).
        #expect(PingTransport.roundTrip(sentAt: 5_000, receivedAt: 4_999) == nil)
        #expect(PingTransport.roundTrip(sentAt: UInt64.max, receivedAt: 0) == nil)
    }

    @Test("the loopback answers through the transport with a measured latency")
    func loopback() throws {
        let transport = try PingTransport.open(address: "127.0.0.1").get()
        defer { transport.close() }
        #expect(transport.send(sequence: 300) == .sent)
        var events: [ConnectivityEvent] = []
        let deadline = Date().addingTimeInterval(1)
        while events.isEmpty, Date() < deadline {
            transport.collect { events.append($0) }
            if events.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard case .answered(let sequence, let latency)? = events.first else {
            Issue.record("no answer from the loopback: \(events)")
            return
        }
        #expect(sequence == 300)
        #expect((latency ?? 1) < 0.5)
    }

    /// Eight is more than the probe ever has outstanding; the bound is what keeps a
    /// session of weeks from growing the list, and the lookup through it, without end.
    @Test("only the last eight send times are kept, so the oldest of nine goes unreported")
    func sendTimesAreBounded() throws {
        let transport = try PingTransport.open(address: "127.0.0.1").get()
        defer { transport.close() }
        for sequence in UInt16(1)...9 {
            #expect(transport.send(sequence: sequence) == .sent)
        }
        var answered: [UInt16] = []
        let collect = { transport.collect { if case .answered(let sequence, _) = $0 { answered.append(sequence) } } }
        let deadline = Date().addingTimeInterval(1)
        // The loopback answers in order, so once the ninth reply is in, the first is too.
        while !answered.contains(9), Date() < deadline {
            collect()
            if !answered.contains(9) { Thread.sleep(forTimeInterval: 0.01) }
        }
        collect()
        #expect(answered.sorted() == Array(UInt16(2)...9))
    }

    @Test("after a reset, an answer to an earlier request is not reported")
    func resetForgetsSendTimes() throws {
        let transport = try PingTransport.open(address: "127.0.0.1").get()
        defer { transport.close() }
        #expect(transport.send(sequence: 1) == .sent)
        Thread.sleep(forTimeInterval: 0.05)
        transport.reset()
        var events: [ConnectivityEvent] = []
        transport.collect { events.append($0) }
        #expect(events.isEmpty)
    }
}
