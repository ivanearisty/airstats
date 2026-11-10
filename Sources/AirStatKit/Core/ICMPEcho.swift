import Darwin
import Foundation

/// ICMP echo requests and the replies that answer them, as bytes.
///
/// Pure functions over byte buffers, so the parts of the check that can be wrong without
/// a network — the checksum, the header offset, telling our replies from everyone
/// else's — are tested without one.
enum ICMPEcho {
    static let headerLength = 8
    /// The payload is a random token rather than a timestamp or a pattern. A datagram
    /// ICMP socket on macOS is handed the echo replies of every process on the machine
    /// (measured: a `/sbin/ping` running alongside delivered its replies into ours), so
    /// the identifier alone, one value in 65,536, is not enough to call a reply ours.
    static let tokenLength = 16
    static let packetLength = headerLength + tokenLength

    /// Fills `buffer` with an echo request. The buffer is the caller's, reused for the
    /// life of the socket, so sending costs no allocation.
    static func writeRequest(into buffer: UnsafeMutableRawBufferPointer,
                             identifier: UInt16, sequence: UInt16, token: [UInt8]) {
        precondition(buffer.count >= packetLength && token.count == tokenLength)
        buffer[0] = 8  // echo request
        buffer[1] = 0
        buffer[2] = 0
        buffer[3] = 0
        buffer[4] = UInt8(truncatingIfNeeded: identifier >> 8)
        buffer[5] = UInt8(truncatingIfNeeded: identifier)
        buffer[6] = UInt8(truncatingIfNeeded: sequence >> 8)
        buffer[7] = UInt8(truncatingIfNeeded: sequence)
        for index in 0..<tokenLength { buffer[headerLength + index] = token[index] }
        let sum = checksum(UnsafeRawBufferPointer(rebasing: buffer[0..<packetLength]))
        buffer[2] = UInt8(truncatingIfNeeded: sum >> 8)
        buffer[3] = UInt8(truncatingIfNeeded: sum)
    }

    /// The RFC 1071 internet checksum: the ones' complement of the ones' complement sum
    /// of the big-endian 16-bit words, an odd trailing byte padded with zero.
    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum &+= UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    /// The sequence number of `datagram` when it is an echo reply to one of our
    /// requests, and nil for anything else.
    ///
    /// The kernel prepends the IPv4 header on a datagram ICMP socket (measured on
    /// macOS 27: every datagram begins 0x45), but a bare ICMP message is accepted too,
    /// so the same code reads either. Options are skipped by the header's own length.
    /// No checksum is verified: the kernel drops a corrupt ICMP message before any
    /// socket sees it, and a reply carrying our identifier, our token and a sequence we
    /// sent has made the round trip whatever its checksum says.
    static func matchReply(_ datagram: UnsafeRawBufferPointer,
                           identifier: UInt16, token: [UInt8]) -> UInt16? {
        guard token.count == tokenLength, let first = datagram.first else { return nil }
        var offset = 0
        if first >> 4 == 4 {
            let ipHeaderLength = Int(first & 0x0F) * 4
            guard ipHeaderLength >= 20, datagram.count >= ipHeaderLength,
                  datagram[9] == UInt8(IPPROTO_ICMP) else { return nil }
            offset = ipHeaderLength
        }
        guard datagram.count - offset >= packetLength,
              datagram[offset] == 0, datagram[offset + 1] == 0 else { return nil }
        let replyIdentifier = UInt16(datagram[offset + 4]) << 8 | UInt16(datagram[offset + 5])
        guard replyIdentifier == identifier else { return nil }
        for index in 0..<tokenLength where datagram[offset + headerLength + index] != token[index] {
            return nil
        }
        return UInt16(datagram[offset + 6]) << 8 | UInt16(datagram[offset + 7])
    }

    /// Seconds in a span of `mach_absolute_time` ticks, which is the clock the kernel
    /// stamps received datagrams with under `SO_TIMESTAMP_MONOTONIC`.
    static func seconds(fromMachTicks ticks: UInt64) -> TimeInterval {
        Double(ticks) * timebase
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
}

/// One non-blocking datagram ICMP socket, aimed at one IPv4 address.
///
/// Confined to `SamplingCore`'s queue like the collector that owns it, so it holds its
/// buffers without locking. Nothing here waits: `send` returns as soon as the kernel
/// has the packet, and `drain` returns as soon as the receive queue is empty.
final class ICMPEchoSocket {

    enum SendOutcome: Equatable {
        /// The kernel accepted the request at this `mach_absolute_time`.
        case sent(at: UInt64)
        /// The send buffer was full. Not a failure of the path, so not a miss.
        case notSent
        /// There is no way out to the address: the path is down.
        case failed(String)
        /// Something on this Mac would not let the packet out. Says nothing about the
        /// path.
        case blocked(String)
    }

    struct Reply: Equatable {
        var sequence: UInt16
        /// The kernel's `mach_absolute_time` at arrival, or nil when the socket could
        /// not be asked for one. Never substituted with the time it was read, which can
        /// be a whole sample later.
        var receivedAt: UInt64?
    }

    let identifier: UInt16
    let address: String
    private let token: [UInt8]
    private var descriptor: Int32
    private let destination: sockaddr_in
    private(set) var hasKernelTimestamps: Bool
    /// Set by `close()`, after which nothing reopens the socket.
    private var isClosed = false
    /// Datagrams read off the socket, ours or not. For tests: the filter is the point.
    private(set) var datagramsRead = 0

    /// Allocated once. A reply to our request is 44 bytes; anything that does not fit
    /// is someone else's, and is dropped as truncated.
    private let sendBuffer: UnsafeMutableRawBufferPointer
    private let receiveBuffer: UnsafeMutableRawBufferPointer
    private let controlBuffer: UnsafeMutableRawBufferPointer
    private static let receiveCapacity = 256
    private static let controlCapacity = 64

    /// Opens the socket, or says why it cannot be opened.
    static func open(address: String) -> Result<ICMPEchoSocket, ConnectivityFailure> {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else {
            return .failure(.init("\(address) is not an IPv4 address."))
        }
        return makeDescriptor(destination: destination).map { made in
            ICMPEchoSocket(descriptor: made.descriptor, destination: destination,
                           address: address, hasKernelTimestamps: made.isStamped)
        }
    }

    /// A non-blocking ICMP datagram socket, connected to `destination`.
    ///
    /// Connected because an unconnected one is handed every echo reply on the Mac, into
    /// an 8 KB buffer (`net.inet.raw.recvspace`): another app's ping would cost a read per
    /// reply here, and a fast one would fill the buffer and drop our own reply, which
    /// reads as a miss. Connected, the kernel discards datagrams from any other address
    /// before they are queued. On an ICMP datagram socket `connect` only records the
    /// address and consults no route, so it has no reason to fail.
    private static func makeDescriptor(destination: sockaddr_in)
        -> Result<(descriptor: Int32, isStamped: Bool), ConnectivityFailure> {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard descriptor >= 0 else {
            return .failure(.init("macOS would not open a ping socket: \(String(cString: strerror(errno))). "
                                  + "An https:// address works without one."))
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            return .failure(.init("macOS would not make the ping socket non-blocking: \(reason)."))
        }
        // Not inherited by anything this process launches, the updater's installer
        // among them.
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        // A send macOS refuses on a connected socket fails with EPIPE, and without this
        // the kernel's SIGPIPE would end the app. Local Network privacy refuses a ping to a
        // LAN address exactly that way (measured: exit 141, on every launch while access
        // stayed denied).
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let isStamped = setsockopt(descriptor, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC,
                                   &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        var target = destination
        let connected = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                connect(descriptor, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            return .failure(.init("macOS would not connect the ping socket: \(reason)."))
        }
        return .success((descriptor, isStamped))
    }

    private init(descriptor: Int32, destination: sockaddr_in, address: String,
                 hasKernelTimestamps: Bool) {
        self.descriptor = descriptor
        self.destination = destination
        self.address = address
        self.hasKernelTimestamps = hasKernelTimestamps
        self.identifier = UInt16.random(in: 0...UInt16.max)
        var token = [UInt8](repeating: 0, count: ICMPEcho.tokenLength)
        arc4random_buf(&token, token.count)
        self.token = token
        sendBuffer = .allocate(byteCount: ICMPEcho.packetLength, alignment: 4)
        receiveBuffer = .allocate(byteCount: Self.receiveCapacity, alignment: 8)
        controlBuffer = .allocate(byteCount: Self.controlCapacity, alignment: 8)
    }

    deinit {
        close()
        sendBuffer.deallocate()
        receiveBuffer.deallocate()
        controlBuffer.deallocate()
    }

    var isOpen: Bool { descriptor >= 0 }

    /// Shuts the socket for sending, which is what macOS does to a connected ping socket
    /// when Local Network privacy refuses its address. For tests: the refusal itself
    /// cannot be provoked on demand.
    func shutForSending() { _ = shutdown(descriptor, SHUT_WR) }

    func close() {
        isClosed = true
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func send(sequence: UInt16) -> SendOutcome {
        guard !isClosed else { return .failed("the ping socket is closed") }
        guard descriptor >= 0 || reopen() else {
            return .blocked("macOS would not open a new ping socket")
        }
        ICMPEcho.writeRequest(into: sendBuffer, identifier: identifier, sequence: sequence, token: token)
        let sentAt = mach_absolute_time()
        let written = Darwin.send(descriptor, sendBuffer.baseAddress, ICMPEcho.packetLength, 0)
        if written == ICMPEcho.packetLength { return .sent(at: sentAt) }
        let code = written < 0 ? errno : EIO
        if code == EPIPE {
            // A refused socket is shut for good (measured: it goes defunct, never sends
            // again even once access is allowed, and refuses a second connect), so the
            // next request goes out on a new one.
            Darwin.close(descriptor)
            descriptor = -1
            _ = reopen()
        }
        return Self.outcome(for: code, address: address)
    }

    private func reopen() -> Bool {
        guard case .success(let made) = Self.makeDescriptor(destination: destination) else { return false }
        descriptor = made.descriptor
        hasKernelTimestamps = made.isStamped
        return true
    }

    /// Not private: no firewall is at hand to provoke these codes in a test.
    static func outcome(for code: Int32, address: String) -> SendOutcome {
        switch code {
        case EAGAIN, ENOBUFS:
            return .notSent
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN, EADDRNOTAVAIL:
            return .failed("No route to \(address)")
        case EPERM, EACCES, EPIPE:
            // A content filter or firewall that blocks ICMP answers EPERM; Local Network
            // privacy refusing a LAN address shuts the connected socket, which is EPIPE.
            // Neither says anything about the internet.
            guard ConnectivityTarget.ping(address).isLocalNetwork else {
                return .blocked("Something on this Mac blocked the ping to \(address)")
            }
            return .blocked("macOS has not allowed AirStats on the local network. Allow it in "
                            + "System Settings › Privacy & Security › Local Network.")
        default:
            return .failed(String(cString: strerror(code)))
        }
    }

    /// Reads every datagram waiting on the socket, up to `limit`, and reports the ones
    /// that are our replies. Returns without blocking when the queue is empty.
    ///
    /// The socket is connected, so only datagrams from the target are queued at all, and
    /// the limit matters only behind a flood of pings to that same address from another
    /// app. Whatever it leaves is read on the next sample.
    func drain(limit: Int = 128, _ body: (Reply) -> Void) {
        guard descriptor >= 0 else { return }
        for _ in 0..<limit {
            var vector = iovec(iov_base: receiveBuffer.baseAddress, iov_len: receiveBuffer.count)
            let (received, stamp): (Int, UInt64?) = withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr(msg_name: nil, msg_namelen: 0,
                                     msg_iov: vectorPointer, msg_iovlen: 1,
                                     msg_control: controlBuffer.baseAddress,
                                     msg_controllen: socklen_t(controlBuffer.count),
                                     msg_flags: 0)
                let count = recvmsg(descriptor, &message, MSG_DONTWAIT)
                guard count > 0 else { return (count, nil) }
                // Larger than any reply of ours, so cut short and not worth reading.
                if message.msg_flags & MSG_TRUNC != 0 { return (0, nil) }
                guard hasKernelTimestamps else { return (count, nil) }
                return (count, Self.monotonicStamp(control: controlBuffer,
                                                   length: Int(message.msg_controllen)))
            }
            if received < 0 { return }  // EAGAIN: the queue is empty
            datagramsRead &+= 1
            guard received > 0,
                  let sequence = ICMPEcho.matchReply(
                      UnsafeRawBufferPointer(rebasing: receiveBuffer[0..<received]),
                      identifier: identifier, token: token) else { continue }
            body(Reply(sequence: sequence, receivedAt: stamp))
        }
    }

    /// The `SCM_TIMESTAMP_MONOTONIC` value among the control messages, if present.
    /// Walked by hand because Swift has no `CMSG_` macros; Darwin aligns each header
    /// and its data to four bytes.
    private static func monotonicStamp(control: UnsafeMutableRawBufferPointer, length: Int) -> UInt64? {
        let headerSize = MemoryLayout<cmsghdr>.size
        let dataOffset = (headerSize + 3) & ~3
        var offset = 0
        let end = min(length, control.count)
        while offset + headerSize <= end {
            let header = control.load(fromByteOffset: offset, as: cmsghdr.self)
            let headerLength = Int(header.cmsg_len)
            guard headerLength >= headerSize, offset + headerLength <= end else { return nil }
            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_TIMESTAMP_MONOTONIC,
               headerLength >= dataOffset + MemoryLayout<UInt64>.size {
                return control.loadUnaligned(fromByteOffset: offset + dataOffset, as: UInt64.self)
            }
            offset += (headerLength + 3) & ~3
        }
        return nil
    }
}

/// Why the check could not run, or why a request failed.
public struct ConnectivityFailure: Error, Sendable, Equatable, Hashable {
    public let message: String
    /// Something on this Mac kept the request in, rather than the network failing to
    /// answer it, so it says nothing about the internet and is never counted as a miss.
    public let isRefusal: Bool

    public init(_ message: String, isRefusal: Bool = false) {
        self.message = message
        self.isRefusal = isRefusal
    }
}
