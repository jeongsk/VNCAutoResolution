import XCTest
@testable import VNCAutoResolutionCore

final class NetstatParserTests: XCTestCase {
    func testIPv4IncomingConnectionIsClient() {
        let out = "tcp4       0      0  192.168.0.10.5900      192.168.0.5.54321      ESTABLISHED"
        XCTAssertEqual(NetstatParser.parse(out), ["192.168.0.5"])
    }

    func testIPv6IncomingConnectionIsClient() {
        let out = "tcp6       0      0  fe80::1.5900           fe80::2.54321          ESTABLISHED"
        XCTAssertEqual(NetstatParser.parse(out), ["fe80::2"])
    }

    func testOutgoingConnectionToPort5900IsExcluded() {
        let v4 = "tcp4       0      0  192.168.0.5.54321      192.168.0.10.5900      ESTABLISHED"
        let v6 = "tcp6       0      0  fe80::2.54321          fe80::1.5900           ESTABLISHED"
        XCTAssertEqual(NetstatParser.parse(v4 + "\n" + v6), [])
    }

    func testNonEstablishedAndOtherPortsAreExcluded() {
        let out = """
        tcp4       0      0  *.5900                 *.*                    LISTEN
        tcp4       0      0  192.168.0.10.5900      192.168.0.5.54321      TIME_WAIT
        tcp4       0      0  192.168.0.10.59000     192.168.0.5.54322      ESTABLISHED
        tcp4       0      0  192.168.0.10.22        192.168.0.5.54323      ESTABLISHED
        udp4       0      0  192.168.0.10.5900      192.168.0.5.54324      ESTABLISHED
        """
        XCTAssertEqual(NetstatParser.parse(out), [])
    }

    func testDuplicateClientsAreMergedAndHeaderIgnored() {
        let out = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  10.0.0.1.5900          10.0.0.2.50001         ESTABLISHED
        tcp4       0      0  10.0.0.1.5900          10.0.0.2.50002         ESTABLISHED
        tcp4       0      0  10.0.0.1.5900          10.0.0.3.50003         ESTABLISHED
        """
        XCTAssertEqual(NetstatParser.parse(out), ["10.0.0.2", "10.0.0.3"])
    }
}
