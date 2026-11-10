import Darwin
import Foundation

/// What the connectivity check talks to, parsed out of the one text field the user
/// types it into.
///
/// An IPv4 address is pinged. Anything else that names a host is asked for over HTTPS,
/// and the settings pane says back which of the two it will be, so the rule is visible
/// rather than inferred. There is no third kind: a bare name could be resolved and then
/// pinged, but that is a DNS lookup on the sampling queue, which blocks it for as long
/// as the resolver takes — and asking the host over HTTPS proves more anyway.
public enum ConnectivityTarget: Sendable, Equatable, Hashable {
    /// A dotted IPv4 address, in the form `inet_ntop` writes it back.
    case ping(String)
    case https(URL)

    public enum Method: String, Sendable, Equatable, Hashable {
        case ping, https
    }

    /// Cloudflare's resolver: anycast, so the nearest instance answers, and it is the
    /// address a person is most likely to recognise in a settings field.
    public static let defaultText = "1.1.1.1"

    /// Seconds between HTTPS checks while the connection is known to work. Public so the
    /// settings pane quotes the real number instead of a copy of it.
    public static let httpsCheckInterval: TimeInterval = 10

    /// Seconds between pings at an update interval, for the same reason. The network is
    /// sampled at most once a second, and never pinged twice within the probe's floor,
    /// so the half-second and one-second intervals ping on every other sample.
    public static func pingInterval(updateInterval: TimeInterval) -> TimeInterval {
        let sample = max(updateInterval, NetworkCollector.fastestInterval)
        return (ConnectivityProbe.minimumSpacing / sample).rounded(.up) * sample
    }

    /// The same for HTTPS: a request goes out on the first sample at least ten seconds
    /// after the last, so the slower intervals stretch it (twelve at three seconds,
    /// thirty at thirty).
    public static func httpsInterval(updateInterval: TimeInterval) -> TimeInterval {
        let sample = max(updateInterval, NetworkCollector.fastestInterval)
        return (httpsCheckInterval / sample).rounded(.up) * sample
    }

    public var method: Method {
        switch self {
        case .ping: return .ping
        case .https: return .https
        }
    }

    /// The address exactly as the check will use it.
    public var displayText: String {
        switch self {
        case .ping(let address): return address
        case .https(let url): return url.absoluteString
        }
    }

    /// The host alone, for the places too narrow for a whole URL.
    public var hostText: String {
        switch self {
        case .ping(let address): return address
        case .https(let url): return url.host ?? url.absoluteString
        }
    }

    /// A ping target inside a private, link-local or carrier-grade NAT range: a router, a
    /// NAS, a machine on the tailnet. Allowed, since "is the router up" is a fair thing to
    /// watch, but the settings pane says the light then shows that device, not the
    /// internet: the router answers just as well with the line behind it dead.
    public var isLocalNetwork: Bool {
        guard case .ping(let text) = self else { return false }
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return false }
        let host = UInt32(bigEndian: address.s_addr)
        return host >> 24 == 10                       // 10.0.0.0/8
            || host >> 20 == 0xAC1                    // 172.16.0.0/12
            || host >> 16 == 0xC0A8                   // 192.168.0.0/16
            || host >> 16 == 0xA9FE                   // 169.254.0.0/16
            || host >> 22 == (100 << 2 | 1)           // 100.64.0.0/10
    }

    /// A field this long is a paste accident, and nothing past it is worth parsing.
    static let maximumLength = 2_048

    public static func parse(_ text: String) -> Result<ConnectivityTarget, ConnectivityTargetError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.utf8.count <= maximumLength else { return .failure(.unrecognised) }
        guard !trimmed.contains(where: \.isWhitespace) else { return .failure(.unrecognised) }

        // Digits and dots alone are an IPv4 address or a mistake. Letting "1.1.1" fall
        // through to the name rules would turn a typo into an HTTPS request for a host
        // called "1.1.1".
        if trimmed.allSatisfy({ $0 == "." || $0.isASCII && $0.isNumber }) {
            return ipv4(trimmed)
        }

        if isIPv6Literal(trimmed) { return .failure(.ipv6Ping) }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("https://") { return https(trimmed) }
        if lowered.hasPrefix("http://") { return .failure(.plainHTTP) }
        if trimmed.contains("://") { return .failure(.unrecognised) }

        // `URL(string:)` reads "example.com:8443" as the scheme "example.com", so a colon
        // has to be classified before anything parses it: a port after a name, or a
        // scheme like "javascript:" that has no business here.
        if let colon = trimmed.firstIndex(of: ":") {
            let after = trimmed[trimmed.index(after: colon)...]
            guard let next = after.first, next.isASCII, next.isNumber else {
                return .failure(.unrecognised)
            }
        }
        return https("https://" + trimmed)
    }

    private static func ipv4(_ text: String) -> Result<ConnectivityTarget, ConnectivityTargetError> {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return .failure(.malformedIPv4) }
        let host = UInt32(bigEndian: address.s_addr)
        // This network (0/8), the multicast block and the reserved block above it (which
        // takes in the limited broadcast): none of them is one host, and a multicast echo
        // is answered by every member that cares to.
        if host >> 24 == 0 || host >> 28 >= 0xE {
            return .failure(.notOneHost)
        }
        // The kernel answers the loopback itself, so the light would be green with every
        // cable pulled.
        if host >> 24 == 127 { return .failure(.loopback) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return .failure(.malformedIPv4)
        }
        return .success(.ping(String(cString: buffer)))
    }

    private static func isIPv6Literal(_ text: String) -> Bool {
        var stripped = Substring(text)
        if stripped.hasPrefix("["), stripped.hasSuffix("]") {
            stripped = stripped.dropFirst().dropLast()
        }
        var address = in6_addr()
        return inet_pton(AF_INET6, String(stripped), &address) == 1
    }

    private static func https(_ text: String) -> Result<ConnectivityTarget, ConnectivityTargetError> {
        guard var components = URLComponents(string: text),
              let decoded = components.host, !decoded.isEmpty else {
            return .failure(.unrecognised)
        }
        // Credentials in the address would ride along on every check.
        guard components.user == nil, components.password == nil else {
            return .failure(.credentials)
        }
        if let port = components.port, !(1...65_535).contains(port) { return .failure(.unrecognised) }
        // `host` is IDNA-decoded and keeps an IPv6 literal's brackets; setting it back
        // yields the ASCII form the resolver will be asked for.
        components.host = decoded.lowercased()
        guard let host = components.encodedHost else { return .failure(.unrecognised) }
        let bracketed = host.hasPrefix("[") && host.hasSuffix("]")
        let literal = bracketed ? String(host.dropFirst().dropLast()) : host
        var v6 = in6_addr()
        let valid = bracketed ? inet_pton(AF_INET6, literal, &v6) == 1
                              : isHostName(host) || isAddressLiteral(host)
        guard valid else { return .failure(.unrecognised) }
        if isThisMac(literal) { return .failure(.loopback) }
        components.scheme = "https"
        components.fragment = nil
        guard let url = components.url else { return .failure(.unrecognised) }
        return .success(.https(url))
    }

    /// RFC 1123 labels: letters, digits and inner hyphens, 63 to a label, 253 in all.
    /// Anything else would be refused by the resolver a moment later, with an error far
    /// less clear than this one.
    private static func isHostName(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.utf8.count),
                  label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ byte in
                      (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                          || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
                  }) else { return false }
        }
        return true
    }

    private static func isThisMac(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name == "localhost." || name.hasSuffix(".localhost")
            || name.hasSuffix(".localhost.") { return true }
        var v4 = in_addr()
        // inet_aton, not inet_pton: Network.framework reads "0x7f.1" as 127.0.0.1 too.
        if inet_aton(name, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }
            if bytes.prefix(12).elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]) { return bytes[12] == 127 }
        }
        return false
    }

    private static func isAddressLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}

/// Why an address cannot be checked, phrased for the line under the field.
public struct ConnectivityTargetError: Error, Sendable, Equatable, Hashable {
    public let message: String

    public init(_ message: String) { self.message = message }

    static let empty = Self("Enter an IPv4 address to ping, such as 1.1.1.1, or an https:// address.")
    static let unrecognised = Self("That is not an IPv4 address or an https:// address.")
    static let malformedIPv4 = Self("That is not a complete IPv4 address.")
    static let notOneHost = Self("Ping needs the address of one host, not a broadcast, multicast or reserved address.")
    static let loopback = Self("That is this Mac's own address, which always answers. Enter an address out on the network.")
    static let ipv6Ping = Self("Ping takes an IPv4 address. For an IPv6 host, enter it as an https:// address.")
    static let plainHTTP = Self("Use https://. A hotel or airport login page answers plain HTTP itself, "
                                + "so the check would pass without the internet.")
    static let credentials = Self("Leave the user name and password out of the address.")
}
