import XCTest
@testable import VNCAutoResolutionCore

/// 메시지 코덱, 프레이밍, 주소 파싱, 백오프 등 순수 로직.
final class PeerProtocolTests: XCTestCase {
    func testMessagesRoundTripAsSingleLineJSON() throws {
        let messages: [PeerMessage] = [
            .hello(deviceID: "a", name: "맥", protocolVersion: 1, route: nil),
            .hello(deviceID: "a", name: "맥", protocolVersion: 1, route: .bonjour),
            .input(deviceID: "a", sourceID: "com.apple.keylayout.ABC", isKorean: false),
            .session(deviceID: "a", active: true),
        ]
        for message in messages {
            let data = PeerCodec.encode(message)
            XCTAssertEqual(data.last, 0x0A)
            XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
            XCTAssertEqual(PeerCodec.decode(data.dropLast()), message)
        }
    }

    func testHelloWireFormat() throws {
        let line = #"{"type":"hello","deviceID":"d1","name":"N","protocolVersion":1}"#
        XCTAssertEqual(
            PeerCodec.decode(Data(line.utf8)),
            .hello(deviceID: "d1", name: "N", protocolVersion: 1, route: nil))
    }

    func testFramerHandlesSplitAndMergedChunks() {
        var framer = MessageFramer()
        XCTAssertEqual(framer.append(Data("ab".utf8)), [])
        XCTAssertEqual(framer.append(Data("c\nde".utf8)), [Data("abc".utf8)])
        XCTAssertEqual(framer.append(Data("f\n\ng\nh".utf8)), [Data("def".utf8), Data("g".utf8)])
        XCTAssertEqual(framer.append(Data("\n".utf8)), [Data("h".utf8)])
    }

    func testFramerDropsOversizedLineAndRecovers() {
        var framer = MessageFramer(maxLineLength: 5)
        XCTAssertEqual(framer.append(Data("123456789".utf8)), [])      // 한도 초과, 끝은 아직
        XCTAssertEqual(framer.append(Data("0\nok\n".utf8)), [Data("ok".utf8)])
        XCTAssertEqual(framer.oversizedCount, 1)
        XCTAssertEqual(framer.append(Data("toolong\nfine\n".utf8)), [Data("fine".utf8)])
        XCTAssertEqual(framer.oversizedCount, 2)
    }

    func testFramerByteByByte() {
        var framer = MessageFramer()
        var lines: [Data] = []
        for byte in Array("one\ntwo\n".utf8) { lines += framer.append(Data([byte])) }
        XCTAssertEqual(lines, [Data("one".utf8), Data("two".utf8)])
    }

    func testRateLimiterWindow() {
        var limiter = RateLimiter(maxCount: 2, interval: 1)
        let t0 = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(limiter.allow(at: t0))
        XCTAssertTrue(limiter.allow(at: t0.addingTimeInterval(0.1)))
        XCTAssertFalse(limiter.allow(at: t0.addingTimeInterval(0.2)))
        XCTAssertTrue(limiter.allow(at: t0.addingTimeInterval(1.1)))
    }

    func testBackoffGrowsAndCaps() {
        let b = Backoff(base: 1, max: 30)
        XCTAssertEqual((0..<7).map { b.delay(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30])
        XCTAssertEqual(b.delay(attempt: Int.max), 30)
    }

    func testPeerAddressParsing() {
        let d = PeerDefaults.port
        XCTAssertEqual(PeerAddress.parse("100.64.0.2"), PeerAddress(host: "100.64.0.2", port: d))
        XCTAssertEqual(PeerAddress.parse(" mac.local:4000 "), PeerAddress(host: "mac.local", port: 4000))
        XCTAssertEqual(PeerAddress.parse("[fd7a::1]:4000"), PeerAddress(host: "fd7a::1", port: 4000))
        XCTAssertEqual(PeerAddress.parse("[fd7a::1]"), PeerAddress(host: "fd7a::1", port: d))
        XCTAssertEqual(PeerAddress.parse("fd7a::1"), PeerAddress(host: "fd7a::1", port: d))
        XCTAssertNil(PeerAddress.parse(""))
        XCTAssertNil(PeerAddress.parse("host:abc"))
        XCTAssertNil(PeerAddress.parse("host:0"))
        XCTAssertNil(PeerAddress.parse(":4000"))
    }

    func testPairingKeyDependsOnPassphrase() {
        XCTAssertEqual(PairingKey.derive(passphrase: "a"), PairingKey.derive(passphrase: "a"))
        XCTAssertNotEqual(PairingKey.derive(passphrase: "a"), PairingKey.derive(passphrase: "b"))
        XCTAssertEqual(PairingKey.derive(passphrase: "a").count, 32)
    }

    /// Bonjour 서비스 타입이 Info.plist 의 NSBonjourServices 와 일치해야 한다 (불일치하면 macOS 15+에서 조용히 실패).
    func testServiceTypeMatchesInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let services = try XCTUnwrap(dict["NSBonjourServices"] as? [String])
        XCTAssertEqual(services, [PeerDefaults.serviceType])
    }
}
