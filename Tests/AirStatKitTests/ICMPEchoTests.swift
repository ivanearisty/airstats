import Testing
import Foundation
@testable import AirStatKit

/// The echo codec is the part of the probe that has to be right byte for byte and can
/// be checked without a network. The checksums here were computed by an independent
/// implementation (Python, RFC 1071 arithmetic), not by the code under test.
@Suite("ICMP echo codec")
struct ICMPEchoTests {

    private static let token = Array("AIRSTATS-PROBE!!".utf8)

    private func request(identifier: UInt16, sequence: UInt16,
                         token: [UInt8] = ICMPEchoTests.token) -> [UInt8] {
        var buffer = [UInt8](repeating: 0xAA, count: ICMPEcho.packetLength)
        buffer.withUnsafeMutableBytes {
            ICMPEcho.writeRequest(into: $0, identifier: identifier, sequence: sequence, token: token)
        }
        return buffer
    }

    /// An echo reply as it arrives on a datagram ICMP socket: the kernel prepends the
    /// IPv4 header (measured on macOS 27: the first byte of every datagram is 0x45).
    private func reply(identifier: UInt16, sequence: UInt16, token: [UInt8] = ICMPEchoTests.token,
                       type: UInt8 = 0, code: UInt8 = 0, ipHeader: Bool = true,
                       headerWords: UInt8 = 5, ipProtocol: UInt8 = 1) -> [UInt8] {
        var icmp: [UInt8] = [type, code, 0, 0,
                             UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                             UInt8(sequence >> 8), UInt8(sequence & 0xFF)] + token
        let sum = icmp.withUnsafeBytes { ICMPEcho.checksum($0) }
        icmp[2] = UInt8(sum >> 8)
        icmp[3] = UInt8(sum & 0xFF)
        guard ipHeader else { return icmp }
        let headerLength = Int(headerWords) * 4
        var ip = [UInt8](repeating: 0, count: max(headerLength, 20))
        ip[0] = 0x40 | (headerWords & 0x0F)
        let total = UInt16(ip.count + icmp.count)
        ip[2] = UInt8(total >> 8)
        ip[3] = UInt8(total & 0xFF)
        ip[8] = 57
        ip[9] = ipProtocol
        ip[12...15] = [1, 1, 1, 1]
        ip[16...19] = [10, 0, 0, 69]
        return ip + icmp
    }

    private func match(_ bytes: [UInt8], identifier: UInt16,
                       token: [UInt8] = ICMPEchoTests.token) -> UInt16? {
        bytes.withUnsafeBytes { ICMPEcho.matchReply($0, identifier: identifier, token: token) }
    }

    // MARK: Requests

    @Test("a request is laid out as RFC 792 says, with an independently computed checksum")
    func requestLayout() {
        let packet = request(identifier: 0xBEEF, sequence: 7)
        #expect(packet.count == 24)
        #expect(packet.map { String(format: "%02x", $0) }.joined()
                == "080019d2beef000741495253544154532d50524f42452121")
    }

    @Test("the checksum folds its carries the way ones' complement requires")
    func checksumKnownAnswers() {
        #expect(request(identifier: 0x1234, sequence: 22136)[2...3] == [0x70, 0x1C])
        // 0x0000 and 0xFFFF are both zero in ones' complement, so these two packets
        // must checksum identically. An implementation that drops the end-around carry
        // gets one of them wrong.
        #expect(request(identifier: 0, sequence: 0)[2...3] == [0xD8, 0xC8])
        #expect(request(identifier: 0xFFFF, sequence: 0xFFFF)[2...3] == [0xD8, 0xC8])
        // RFC 1071's own worked example.
        let words: [UInt8] = [0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]
        #expect(words.withUnsafeBytes { ICMPEcho.checksum($0) } == 0x220D)
        // An odd byte is padded with a zero, as the RFC specifies.
        #expect([UInt8]([1, 2, 3]).withUnsafeBytes { ICMPEcho.checksum($0) } == 0xFBFD)
    }

    /// 0xFFFF + 0xFFFF + 0x0001 is 0x1FFFF, and one fold leaves 0x10000, which carries
    /// again. RFC 1071 arithmetic (computed in Python) gives 0xFFFE; stopping after one
    /// fold gives 0xFFFF. About one real request in fifteen thousand needs the second
    /// fold, and the kernel drops a request whose checksum is wrong.
    @Test("a sum that still carries after one fold is folded again")
    func checksumFoldsUntilNoCarryIsLeft() {
        let bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01]
        #expect(bytes.withUnsafeBytes { ICMPEcho.checksum($0) } == 0xFFFE)
    }

    @Test("a request verifies to zero across the whole sequence space")
    func requestsVerify() {
        for sequence in stride(from: 0, through: Int(UInt16.max), by: 257) {
            let packet = request(identifier: 0xA1B2, sequence: UInt16(sequence))
            #expect(packet.withUnsafeBytes { ICMPEcho.checksum($0) } == 0, "\(sequence)")
        }
    }

    // MARK: Replies

    @Test("our reply is recognised with the IPv4 header in front of it")
    func replyWithIPHeader() {
        #expect(match(reply(identifier: 0xBEEF, sequence: 7), identifier: 0xBEEF) == 7)
    }

    @Test("our reply is recognised without an IPv4 header too")
    func replyWithoutIPHeader() {
        #expect(match(reply(identifier: 0xBEEF, sequence: 9, ipHeader: false), identifier: 0xBEEF) == 9)
    }

    @Test("IPv4 options are skipped by the header length, not assumed to be absent")
    func ipOptionsAreSkipped() {
        #expect(match(reply(identifier: 0xBEEF, sequence: 3, headerWords: 6), identifier: 0xBEEF) == 3)
    }

    @Test("bytes after the token do not stop a match")
    func trailingPaddingIsAllowed() {
        let padded = reply(identifier: 0xBEEF, sequence: 11) + [0, 0, 0, 0]
        #expect(match(padded, identifier: 0xBEEF) == 11)
    }

    /// Measured: a datagram ICMP socket on macOS receives the echo replies of every
    /// process on the machine. A `ping` running in Terminal must not light our light.
    @Test("another process's reply is not ours")
    func foreignRepliesAreIgnored() {
        #expect(match(reply(identifier: 0xCE2E, sequence: 0), identifier: 0xBEEF) == nil)
        // Same identifier by coincidence (1 in 65,536), different payload.
        let otherToken = Array("SOMEONE-ELSE-ABC".utf8)
        #expect(match(reply(identifier: 0xBEEF, sequence: 7, token: otherToken), identifier: 0xBEEF) == nil)
    }

    @Test("a token that differs only in its last byte is someone else's")
    func everyTokenByteCounts() {
        var almost = ICMPEchoTests.token
        almost[almost.count - 1] ^= 0x01
        #expect(match(reply(identifier: 0xBEEF, sequence: 7, token: almost), identifier: 0xBEEF) == nil)
    }

    @Test("only an echo reply counts")
    func otherTypesAreIgnored() {
        // Our own request, looped back; a destination unreachable; a time exceeded.
        for (type, code) in [(UInt8(8), UInt8(0)), (3, 1), (11, 0), (0, 1)] {
            #expect(match(reply(identifier: 0xBEEF, sequence: 7, type: type, code: code),
                          identifier: 0xBEEF) == nil, "type \(type) code \(code)")
        }
    }

    @Test("a datagram that claims to be IPv4 but is not ICMP is ignored")
    func wrongProtocolIsIgnored() {
        #expect(match(reply(identifier: 0xBEEF, sequence: 7, ipProtocol: 17), identifier: 0xBEEF) == nil)
    }

    @Test("every truncation of a valid reply is refused without reading past the end")
    func truncationsAreRefused() {
        let full = reply(identifier: 0xBEEF, sequence: 7)
        for length in 0..<full.count {
            #expect(match(Array(full.prefix(length)), identifier: 0xBEEF) == nil, "length \(length)")
        }
        let bare = reply(identifier: 0xBEEF, sequence: 7, ipHeader: false)
        for length in 0..<bare.count {
            #expect(match(Array(bare.prefix(length)), identifier: 0xBEEF) == nil, "bare length \(length)")
        }
    }

    @Test("a header length that is too short or runs past the datagram is refused")
    func badHeaderLengthIsRefused() {
        var short = reply(identifier: 0xBEEF, sequence: 7)
        short[0] = 0x44  // four words: shorter than the fixed IPv4 header
        #expect(match(short, identifier: 0xBEEF) == nil)
        var long = reply(identifier: 0xBEEF, sequence: 7)
        long[0] = 0x4F  // sixty bytes of header in a 44-byte datagram
        #expect(match(long, identifier: 0xBEEF) == nil)
    }

    @Test("random bytes never match and never trap")
    func randomBytesAreSafe() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...96, using: &generator)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            #expect(match(bytes, identifier: 0xBEEF) == nil)
        }
    }
}
