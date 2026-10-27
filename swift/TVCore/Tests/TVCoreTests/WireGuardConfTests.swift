import XCTest
@testable import TVCore

final class WireGuardConfTests: XCTestCase {
    func testTypicalProviderConfig() throws {
        let c = try WireGuardConf.parse("""
        [Interface]
        # Bouncing = 4
        PrivateKey = SBt3+xy10Mo/W2vcUvJ2Bg8UvW1FDcCzM53s3Nz+t0M=
        Address = 10.2.0.2/32
        DNS = 10.2.0.1

        [Peer]
        PublicKey = 5UWn/wdKpxPvIV5A18JZWJUW1zGlXCJmXaR0S5ohNzM=
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = 203.0.113.7:51820
        """)
        XCTAssertEqual(c.addresses, [.init(address: "10.2.0.2", length: 32)])
        XCTAssertEqual(c.dns, ["10.2.0.1"])
        XCTAssertNil(c.mtu)
        XCTAssertEqual(c.endpointHost, "203.0.113.7")
        XCTAssertEqual(c.endpointPort, 51820)
        XCTAssertEqual(c.allowedIPs.map(\.address), ["0.0.0.0", "::"])
        XCTAssertEqual(c.allowedIPs.map(\.length), [0, 0])
        XCTAssertEqual(c.allowedIPs.map(\.isIPv6), [false, true])
    }

    func testDualStackWindowsLineEndingsAndAHostname() throws {
        let text = "[Interface]\r\nAddress = 10.0.0.2/24, fd00::2/64\r\nDNS = 1.1.1.1, 2606:4700:4700::1111, example.internal\r\nMTU = 1380\r\n[Peer]\r\nEndpoint = vpn.example.com:443\r\nAllowedIPs = 10.0.0.0/24\r\n"
        let c = try WireGuardConf.parse(text)
        XCTAssertEqual(c.addresses.map(\.address), ["10.0.0.2", "fd00::2"])
        XCTAssertEqual(c.addresses.map(\.length), [24, 64])
        XCTAssertEqual(c.dns, ["1.1.1.1", "2606:4700:4700::1111"], "a search domain is not a server")
        XCTAssertEqual(c.mtu, 1380)
        XCTAssertEqual(c.endpointHost, "vpn.example.com")
        XCTAssertEqual(c.endpointPort, 443)
        XCTAssertEqual(c.addresses[0].ipv4Mask, "255.255.255.0")
    }

    func testIPv6EndpointAndMasks() throws {
        let c = try WireGuardConf.parse("[Interface]\nAddress = 10.1.1.1\n[Peer]\nEndpoint = [2001:db8::1]:51820\n")
        XCTAssertEqual(c.endpointHost, "2001:db8::1")
        XCTAssertEqual(c.endpointPort, 51820)
        XCTAssertEqual(c.addresses[0].length, 32, "a bare address is a host")
        XCTAssertEqual(WireGuardConf.Prefix(address: "0.0.0.0", length: 0).ipv4Mask, "0.0.0.0")
        XCTAssertEqual(WireGuardConf.Prefix(address: "10.0.0.0", length: 8).ipv4Mask, "255.0.0.0")
        XCTAssertEqual(WireGuardConf.Prefix(address: "10.0.0.0", length: 31).ipv4Mask, "255.255.255.254")
    }

    func testOnlyTheFirstPeerCounts() throws {
        let c = try WireGuardConf.parse("[Interface]\nAddress = 10.1.1.1/32\n[Peer]\nEndpoint = 1.1.1.1:1\nAllowedIPs = 10.0.0.0/8\n[Peer]\nEndpoint = 2.2.2.2:2\nAllowedIPs = 0.0.0.0/0\n")
        XCTAssertEqual(c.endpointHost, "1.1.1.1")
        XCTAssertEqual(c.allowedIPs.map(\.address), ["10.0.0.0"])
    }

    func testMissingPiecesAreErrors() {
        XCTAssertThrowsError(try WireGuardConf.parse("[Interface]\nDNS = 1.1.1.1\n[Peer]\nEndpoint = 1.1.1.1:1\n"))
        XCTAssertThrowsError(try WireGuardConf.parse("[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nAllowedIPs = 0.0.0.0/0\n"))
    }
}
