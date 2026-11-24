import Testing
import Foundation
@testable import AirStatKit

/// The address field is free text a person types, so the parser is tested against what
/// people actually type: padding, schemes they half remember, the address families ping
/// cannot reach, and the inputs that would make a probe meaningless.
@Suite("Connectivity target parsing")
struct ConnectivityTargetTests {

    private func parsed(_ text: String) -> ConnectivityTarget? {
        try? ConnectivityTarget.parse(text).get()
    }

    private func refusal(_ text: String) -> String? {
        if case .failure(let error) = ConnectivityTarget.parse(text) { return error.message }
        return nil
    }

    @Test("the shipped default is a ping")
    func defaultIsPing() {
        #expect(parsed(ConnectivityTarget.defaultText) == .ping("1.1.1.1"))
    }

    @Test("an IPv4 address is pinged, padding and all")
    func ipv4IsPinged() {
        #expect(parsed("8.8.8.8") == .ping("8.8.8.8"))
        #expect(parsed("  9.9.9.9\n") == .ping("9.9.9.9"))
        // A router or a machine on the tailnet is a fair thing to watch.
        #expect(parsed("192.168.1.1") == .ping("192.168.1.1"))
        #expect(parsed("100.112.14.9") == .ping("100.112.14.9"))
    }

    @Test("this Mac's own addresses are refused: they answer with every cable pulled")
    func loopbackIsRefused() {
        for text in ["127.0.0.1", "127.1.2.3", "127.255.255.254"] {
            #expect(refusal(text)?.contains("this Mac") == true, "\(text)")
        }
    }

    @Test("a local address is allowed, and known to be one, so the pane can say what the light then means")
    func localNetworkIsRecognised() {
        for text in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1",
                     "169.254.10.20", "100.64.0.1", "100.127.255.255"] {
            #expect(parsed(text)?.isLocalNetwork == true, "\(text)")
        }
        for text in ["1.1.1.1", "8.8.8.8", "172.32.0.1", "172.15.255.255",
                     "100.128.0.1", "100.63.255.255", "192.169.0.1"] {
            #expect(parsed(text)?.isLocalNetwork == false, "\(text)")
        }
        #expect(ConnectivityTarget.https(URL(string: "https://192.168.1.1")!).isLocalNetwork == false)
    }

    @Test("the interval quoted in Settings is how often a ping really goes out")
    func pingInterval() {
        // The network is sampled at most once a second and never pinged twice within
        // 1.5 s, so the two fastest settings ping every other sample.
        let expected: [TimeInterval: TimeInterval] = [0.5: 2, 1: 2, 2: 2, 3: 3, 5: 5, 10: 10, 30: 30]
        for interval in GeneralSettings.allowedIntervals {
            #expect(ConnectivityTarget.pingInterval(updateInterval: interval) == expected[interval],
                    "\(interval)")
        }
    }

    @Test("an https address is fetched")
    func httpsIsFetched() {
        #expect(parsed("https://example.com/health") == .https(URL(string: "https://example.com/health")!))
        #expect(parsed("HTTPS://example.com") == .https(URL(string: "https://example.com")!))
    }

    @Test("a bare name is fetched over https rather than resolved for ping")
    func bareNameIsHTTPS() {
        #expect(parsed("example.com") == .https(URL(string: "https://example.com")!))
        #expect(parsed("example.com:8443/up") == .https(URL(string: "https://example.com:8443/up")!))
        #expect(parsed("router") == .https(URL(string: "https://router")!))
    }

    @Test("plain http is refused, because a login page can answer it")
    func plainHTTPIsRefused() {
        let message = refusal("http://example.com")
        #expect(message?.contains("https://") == true)
    }

    @Test("an IPv6 address is refused for ping and pointed at https")
    func ipv6IsRefused() {
        for text in ["2606:4700:4700::1111", "::1", "[2001:db8::1]"] {
            let message = refusal(text)
            #expect(message?.contains("IPv4") == true, "\(text)")
            #expect(message?.contains("https://") == true, "\(text)")
        }
    }

    /// The catch-all refusal also mentions IPv4 and https://, so checking for those words
    /// cannot tell the specific reasons from it.
    @Test("http and IPv6 are each refused with their own reason, not the catch-all")
    func refusalsSayWhy() {
        #expect(refusal("http://example.com") == ConnectivityTargetError.plainHTTP.message)
        for text in ["2606:4700:4700::1111", "::1", "[2001:db8::1]"] {
            #expect(refusal(text) == ConnectivityTargetError.ipv6Ping.message, "\(text)")
        }
    }

    @Test("a colon with no port after it is refused, javascript: included")
    func colonWithoutPortIsRefused() {
        for text in ["javascript:", "example.com:"] {
            #expect(parsed(text) == nil, "\(text)")
        }
    }

    @Test("a name the resolver would refuse is refused here first")
    func malformedNamesAreRefused() {
        for text in ["example..com", "example-.com"] {
            #expect(parsed(text) == nil, "\(text)")
        }
    }

    @Test("addresses that are not one host are refused")
    func nonUnicastIsRefused() {
        for text in ["0.0.0.0", "0.1.2.3", "255.255.255.255", "224.0.0.1",
                     "239.255.255.250", "240.0.0.1", "250.1.1.1"] {
            #expect(refusal(text) != nil, "\(text)")
        }
    }

    @Test("a malformed IPv4 address is refused rather than looked up as a name")
    func malformedIPv4IsRefused() {
        for text in ["1.1.1", "256.1.1.1", "1.1.1.1.1", "1..1.1", "1.1.1.", "999"] {
            #expect(refusal(text) != nil, "\(text)")
            #expect(parsed(text) == nil, "\(text)")
        }
    }

    @Test("nothing at all is refused, not defaulted")
    func emptyIsRefused() {
        #expect(refusal("") != nil)
        #expect(refusal("   \n\t") != nil)
    }

    @Test("other schemes, credentials and spaces are refused")
    func junkIsRefused() {
        for text in ["ftp://example.com", "file:///etc/hosts", "javascript:alert(1)",
                     "https://", "https:///path", "https://user:secret@example.com",
                     "exa mple.com", "https://exa mple.com", "-", ".", "a/b c"] {
            #expect(parsed(text) == nil, "\(text)")
        }
    }

    @Test("an IPv6 host is accepted in the https:// form the IPv6 refusal recommends")
    func ipv6OverHTTPS() {
        for text in ["https://[2606:4700:4700::1111]", "https://[2001:db8::1]:8443/up"] {
            #expect(parsed(text)?.method == .https, "\(text)")
        }
        #expect(parsed("https://[not:an:address]") == nil)
    }

    @Test("an internationalised name is accepted in either spelling, and asked for in punycode")
    func internationalisedName() {
        for text in ["xn--bcher-kva.example", "https://xn--bcher-kva.example", "https://bücher.example"] {
            #expect(parsed(text)?.displayText == "https://xn--bcher-kva.example", "\(text)")
        }
    }

    @Test("a port outside 1...65535 is refused rather than wrapped onto another port")
    func portRange() {
        for text in ["example.com:99999", "https://example.com:65536", "https://example.com:0"] {
            #expect(parsed(text) == nil, "\(text)")
        }
        #expect(parsed("example.com:65535") != nil)
    }

    @Test("this Mac's own address is refused over https too, however it is spelled")
    func loopbackOverHTTPS() {
        for text in ["127.0.0.1:8443", "https://127.0.0.1", "localhost", "https://localhost:8443",
                     "printer.localhost", "0x7f.1", "0x7f000001", "https://[::1]",
                     "https://[::ffff:127.0.0.1]"] {
            #expect(parsed(text) == nil, "\(text)")
        }
        #expect(parsed("https://localhost.example.com") != nil, "a real name that merely starts with localhost")
    }

    @Test("an absurdly long entry is refused without trouble")
    func oversizedIsRefused() {
        let long = String(repeating: "a", count: 20_000) + ".com"
        #expect(parsed(long) == nil)
        #expect(parsed("https://" + long) == nil)
    }

    @Test("the text shown back is the address that will be used")
    func displayText() {
        #expect(ConnectivityTarget.ping("1.1.1.1").displayText == "1.1.1.1")
        #expect(ConnectivityTarget.https(URL(string: "https://example.com/up")!).displayText
                == "https://example.com/up")
        #expect(ConnectivityTarget.ping("1.1.1.1").method == .ping)
        #expect(ConnectivityTarget.https(URL(string: "https://example.com")!).method == .https)
    }
}
