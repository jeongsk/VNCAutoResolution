import XCTest
@testable import VNCAutoResolutionCore

/// macOS 27에서 실제로 수집한 `nettop -m tcp -L 1 -n -J state` 출력 형식을 기준으로 한다.
final class NettopParserTests: XCTestCase {
    func testIPv4IncomingConnectionIsClient() {
        let out = """
        ,state,
        screensharingd.2912,,
        tcp6 *.5900<->*.*,Listen,
        tcp4 192.168.0.10:5900<->192.168.0.5:49953,Established,
        """
        XCTAssertEqual(NettopParser.parse(out), ["192.168.0.5"])
    }

    func testIPv6IncomingConnectionIsClient() {
        let out = "tcp6 fe80::1%en0.5900<->fe80::2%en0.54321,Established,"
        XCTAssertEqual(NettopParser.parse(out), ["fe80::2%en0"])
    }

    func testOutgoingConnectionToPort5900IsExcluded() {
        let out = """
        tcp4 192.168.0.5:54321<->192.168.0.10:5900,Established,
        tcp6 fe80::2.54321<->fe80::1.5900,Established,
        """
        XCTAssertEqual(NettopParser.parse(out), [])
    }

    func testListenOtherStatesAndSimilarPortsAreExcluded() {
        let out = """
        tcp4 *:5900<->*:*,Listen,
        tcp4 10.0.0.1:5900<->10.0.0.2:50000,TimeWait,
        tcp6 fd3c:20de:5c51::2.59007<->fd3c:20de:5c51::1.50039,Established,
        tcp4 10.0.0.1:22<->10.0.0.2:50001,Established,
        """
        XCTAssertEqual(NettopParser.parse(out), [])
    }

    func testDuplicateClientsAreMerged() {
        let out = """
        tcp4 10.0.0.1:5900<->10.0.0.2:50001,Established,
        tcp4 10.0.0.1:5900<->10.0.0.2:50002,Established,
        tcp4 10.0.0.1:5900<->10.0.0.3:50003,Established,
        """
        XCTAssertEqual(NettopParser.parse(out), ["10.0.0.2", "10.0.0.3"])
    }
}
