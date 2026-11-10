import Darwin
import Foundation

/// The two ways the connectivity check asks the network a question.
///
/// Called only from `SamplingCore`'s queue, through `ConnectivityProbe`. A transport
/// never waits: `send` hands a request to the kernel or to URLSession and returns, and
/// `collect` reports whatever answers have arrived since it was last called.
protocol ConnectivityTransport: AnyObject {
    func send(sequence: UInt16) -> ConnectivitySend
    func collect(_ body: (ConnectivityEvent) -> Void)
    /// Forgets every request in flight. Their answers, if any arrive, are discarded.
    func reset()
    func close()
}

enum ConnectivitySend: Equatable {
    case sent
    /// The transport cannot take another request yet. Not evidence about the network.
    case busy
    /// The request could not leave because there is no way out: evidence the connection
    /// is down, and counted as a miss.
    case failed(String)
    /// Something on this Mac would not let the request out (a content filter, a
    /// firewall). Says nothing about the internet, so it is not a miss.
    case refused(String)
}

enum ConnectivityEvent: Equatable {
    /// The request with this sequence number was answered. `latency` is nil when it
    /// could not be measured, never a guess.
    case answered(sequence: UInt16, latency: TimeInterval?)
    /// The request was definitively not answered, for this reason.
    case failed(sequence: UInt16, reason: String)
    /// Something on this Mac would not let the request out. Not a miss.
    case refused(sequence: UInt16, reason: String)
}

// MARK: - Ping

/// Echo requests over `ICMPEchoSocket`, with the send times needed to turn the kernel's
/// arrival stamps into round trips.
final class PingTransport: ConnectivityTransport {
    private let socket: ICMPEchoSocket
    /// Send times of the last few requests, by sequence number. Eight covers more than
    /// the probe ever has outstanding, and the array is reserved once so a send costs no
    /// allocation.
    private var sentAt: [(sequence: UInt16, at: UInt64)] = []
    private static let capacity = 8

    init(socket: ICMPEchoSocket) {
        self.socket = socket
        sentAt.reserveCapacity(Self.capacity)
    }

    static func open(address: String) -> Result<ConnectivityTransport, ConnectivityFailure> {
        ICMPEchoSocket.open(address: address).map { PingTransport(socket: $0) }
    }

    func send(sequence: UInt16) -> ConnectivitySend {
        switch socket.send(sequence: sequence) {
        case .sent(let at):
            if sentAt.count == Self.capacity { sentAt.removeFirst() }
            sentAt.append((sequence, at))
            return .sent
        case .notSent:
            return .busy
        case .failed(let reason):
            return .failed(reason)
        case .blocked(let reason):
            return .refused(reason)
        }
    }

    func collect(_ body: (ConnectivityEvent) -> Void) {
        socket.drain { reply in
            guard let sent = sentAt.first(where: { $0.sequence == reply.sequence })?.at else { return }
            body(.answered(sequence: reply.sequence,
                           latency: reply.receivedAt.flatMap { Self.roundTrip(sentAt: sent, receivedAt: $0) }))
        }
    }

    /// The kernel stamps arrivals with `mach_absolute_time`, the clock the send was
    /// timed on. A stamp earlier than the send cannot belong to this request, and is
    /// reported as no measurement rather than wrapped into a huge one.
    static func roundTrip(sentAt: UInt64, receivedAt: UInt64) -> TimeInterval? {
        guard receivedAt >= sentAt else { return nil }
        return ICMPEcho.seconds(fromMachTicks: receivedAt - sentAt)
    }

    func reset() { sentAt.removeAll(keepingCapacity: true) }

    func close() {
        reset()
        socket.close()
    }
}

// MARK: - HTTPS

/// What an HTTPS check reports back: a response arrived (any status: a TLS-authenticated
/// server answered, so the path works), or it failed for a reason the user can read.
/// Nil for a request that was cancelled, which is our doing and says nothing about the
/// network.
typealias HTTPSOutcome = Result<Void, ConnectivityFailure>?

/// Starts one request and calls back exactly once, on any thread. Returns a closure that
/// cancels it. Injected so the transport's bookkeeping is tested without a network.
typealias HTTPSFetch = (URL, @escaping @Sendable (HTTPSOutcome) -> Void) -> (() -> Void)

/// HEAD requests through one ephemeral URLSession, at most one in flight.
///
/// The answer arrives on URLSession's delegate queue, so it is left in a locked mailbox
/// for the next sample to collect rather than reaching into the probe from another
/// thread. A generation number marks every request, and `reset` moves it on, so an
/// answer to a request made before a network change or a settings change is discarded
/// even though it cannot be unsent.
final class HTTPSTransport: ConnectivityTransport, @unchecked Sendable {
    private let url: URL
    private let fetch: HTTPSFetch
    private let invalidate: () -> Void

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var inFlight: UInt16?
    private var cancelInFlight: (() -> Void)?
    private var mailbox: [ConnectivityEvent] = []
    private var isClosed = false

    init(url: URL, fetch: @escaping HTTPSFetch, invalidate: @escaping () -> Void = {}) {
        self.url = url
        self.fetch = fetch
        self.invalidate = invalidate
        mailbox.reserveCapacity(2)
    }

    /// The shipping transport: one session for the life of the check, so a request every
    /// ten seconds rides the connection the last one left open instead of paying for DNS,
    /// TCP and TLS each time.
    static func open(url: URL) -> ConnectivityTransport {
        let session = HTTPSSession()
        return HTTPSTransport(url: url, fetch: session.fetch, invalidate: session.invalidate)
    }

    func send(sequence: UInt16) -> ConnectivitySend {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return .failed("the check was stopped")
        }
        guard inFlight == nil else {
            lock.unlock()
            return .busy
        }
        inFlight = sequence
        let generation = self.generation
        lock.unlock()

        let started = Monotonic.now
        let cancel = fetch(url) { [weak self] outcome in
            self?.finish(sequence: sequence, generation: generation, outcome: outcome,
                         latency: Monotonic.seconds(since: started))
        }

        lock.lock()
        // The answer can beat this line back: a request refused on the spot completes
        // before `fetch` has even returned. Only a request still in flight keeps its
        // cancel handle, and one a reset has already disowned is cancelled here.
        let isCurrent = generation == self.generation
        if isCurrent && inFlight == sequence { cancelInFlight = cancel }
        lock.unlock()
        if !isCurrent { cancel() }
        return .sent
    }

    deinit {
        // URLSession holds its delegate until it is invalidated, so a transport dropped
        // without `close()` would otherwise leave the session behind for good.
        if !isClosed { invalidate() }
    }

    private func finish(sequence: UInt16, generation: UInt64, outcome: HTTPSOutcome, latency: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, inFlight == sequence else { return }
        inFlight = nil
        cancelInFlight = nil
        switch outcome {
        case .some(.success):
            mailbox.append(.answered(sequence: sequence, latency: latency))
        case .some(.failure(let failure)) where failure.isRefusal:
            mailbox.append(.refused(sequence: sequence, reason: failure.message))
        case .some(.failure(let failure)):
            mailbox.append(.failed(sequence: sequence, reason: failure.message))
        case .none:
            break
        }
    }

    func collect(_ body: (ConnectivityEvent) -> Void) {
        lock.lock()
        guard !mailbox.isEmpty else {
            lock.unlock()
            return
        }
        let events = mailbox
        mailbox.removeAll(keepingCapacity: true)
        lock.unlock()
        for event in events { body(event) }
    }

    func reset() {
        lock.lock()
        generation &+= 1
        inFlight = nil
        mailbox.removeAll(keepingCapacity: true)
        let cancel = cancelInFlight
        cancelInFlight = nil
        lock.unlock()
        cancel?()
    }

    func close() {
        reset()
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        lock.unlock()
        if !wasClosed { invalidate() }
    }
}

/// The URLSession behind `HTTPSTransport`, and the delegate that stops it following
/// redirects.
///
/// Ephemeral, so no cookie jar, credential store or cache outlives a request, and no
/// redirect is followed: the first response proves the round trip, and following a 301
/// from `https://example.com` to `https://www.example.com` would double the traffic to
/// learn nothing more. `waitsForConnectivity` is off for the reason the public IP lookup
/// gives: an offline Mac should hear that it is offline, not have the question held open
/// until the network returns.
final class HTTPSSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Half the ten seconds between checks, so one request is always over before the
    /// next is due.
    static let timeout: TimeInterval = 5

    /// Made on the first request, so a check that is configured and never runs costs
    /// nothing. Touched only from the sampling queue.
    private var session: URLSession?

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func fetch(_ url: URL, completion: @escaping @Sendable (HTTPSOutcome) -> Void) -> (() -> Void) {
        let session = self.session ?? makeSession()
        self.session = session
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        // CFNetwork's default agent spells out the OS build and the app version. A fixed
        // name says who is asking without describing the machine.
        request.setValue("AirStats", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { _, response, error in
            completion(Self.interpret(url: url, response: response, error: error))
        }
        task.resume()
        return { task.cancel() }
    }

    func invalidate() {
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func interpret(url: URL, response: URLResponse?, error: Error?) -> HTTPSOutcome {
        let host = url.host ?? url.absoluteString
        if let error {
            let code = (error as? URLError)?.code
            if code == .cancelled { return nil }
            // URLSession reports no path while the Mac has a route out (the probe sends
            // nothing without one): something on this Mac is keeping the request in.
            // Local Network privacy refuses a LAN host exactly so (measured: "Local network
            // prohibited"), and so does a VPN that blocks everything outside its tunnel.
            if code == .notConnectedToInternet {
                return .failure(ConnectivityFailure(
                    "macOS would not let AirStats reach \(host). If it is on your local network, "
                        + "allow AirStats in System Settings › Privacy & Security › Local Network.",
                    isRefusal: true))
            }
            return .failure(ConnectivityFailure(reason(for: code, host: host)))
        }
        // Any status at all. A 404 or a 503 still came from the host this URL names, over
        // TLS its certificate vouched for, which is the whole question being asked.
        guard response is HTTPURLResponse else {
            return .failure(ConnectivityFailure("\(host) sent no HTTP response"))
        }
        return .success(())
    }

    /// A few words for the panel's Internet row, which has one line to say it in.
    /// URLError's own descriptions are sentences; what the row needs is which of a few
    /// things went wrong, and the certificate case matters most: it is what a hotel or
    /// airport login page intercepting HTTPS looks like from here.
    static func reason(for code: URLError.Code?, host: String) -> String {
        switch code {
        case .timedOut?: return "\(host) timed out"
        case .cannotFindHost?, .dnsLookupFailed?: return "Couldn't look up \(host)"
        case .cannotConnectToHost?: return "\(host) refused the connection"
        case .networkConnectionLost?: return "The connection to \(host) dropped"
        case .secureConnectionFailed?, .serverCertificateUntrusted?, .serverCertificateHasBadDate?,
             .serverCertificateHasUnknownRoot?, .serverCertificateNotYetValid?:
            return "\(host)'s certificate was refused, as a login page's would be"
        default: return "Couldn't reach \(host)"
        }
    }
}
