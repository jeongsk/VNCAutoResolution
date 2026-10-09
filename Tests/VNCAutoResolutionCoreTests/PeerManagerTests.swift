import XCTest
@testable import VNCAutoResolutionCore

/// 피어 레지스트리/프로토콜 규칙 (가짜 전송으로 검증).
final class PeerManagerTests: XCTestCase {
    private var transport: FakePeerTransport!
    private var stores: InMemoryPeerStores!
    private var clock: FakeClock!
    private var manager: PeerManager!
    private var received: [(PeerMessage, PeerManager.Peer)] = []

    private let me = "mmm"

    override func setUp() {
        transport = FakePeerTransport()
        stores = InMemoryPeerStores(deviceID: me)
        clock = FakeClock()
        received = []
        makeManager()
    }

    private func makeManager(limits: PeerManager.Limits = .init()) {
        manager = PeerManager(
            deviceName: "내 맥", transport: transport, settings: stores, secrets: stores,
            clock: clock, limits: limits)
        manager.onMessage = { [unowned self] message, peer in received.append((message, peer)) }
    }

    private func hello(_ id: String, name: String = "상대", version: Int = 1, route: PeerRoute? = nil) -> Data {
        PeerCodec.encode(.hello(deviceID: id, name: name, protocolVersion: version, route: route))
    }

    // MARK: hello

    func testSendsHelloWhenConnected() {
        manager.handle(.connected(1, route: .manual, isOutbound: true))
        XCTAssertEqual(transport.messages(to: 1), [
            .hello(deviceID: me, name: "내 맥", protocolVersion: 1, route: .manual),
        ])
    }

    func testHelloRegistersPeerWithOutboundRoute() {
        manager.handle(.connected(1, route: .bonjour, isOutbound: true))
        manager.handle(.received(1, hello("aaa", name: "회사 맥")))
        XCTAssertEqual(manager.peers.map(\.name), ["회사 맥"])
        XCTAssertEqual(manager.peers.first?.route, .bonjour)
    }

    func testInboundRouteComesFromHello() {
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, hello("aaa", route: .manual)))
        XCTAssertEqual(manager.peers.first?.route, .manual)
    }

    func testDisconnectRemovesPeer() {
        manager.handle(.connected(1, route: .manual, isOutbound: true))
        manager.handle(.received(1, hello("aaa")))
        manager.handle(.disconnected(1))
        XCTAssertTrue(manager.peers.isEmpty)
    }

    func testIncompatibleProtocolVersionIsClosed() {
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, hello("aaa", version: 99)))
        XCTAssertTrue(manager.peers.isEmpty)
        XCTAssertEqual(transport.closed, [1])
    }

    // MARK: 자기 자신 / 중복

    func testOwnDeviceIDIsIgnoredAndConnectionClosed() {
        manager.handle(.connected(1, route: .manual, isOutbound: true))
        manager.handle(.received(1, hello(me)))
        XCTAssertTrue(manager.peers.isEmpty)
        XCTAssertEqual(transport.closed, [1])
    }

    func testOwnMessageFromEstablishedPeerIsIgnored() {
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, hello("aaa")))
        manager.handle(.received(1, PeerCodec.encode(.session(deviceID: me, active: true))))
        XCTAssertTrue(received.isEmpty)
    }

    func testDuplicateDeviceIDKeepsSingleConnectionDialedBySmallerDeviceID() {
        // 상대 "aaa" < 나 "mmm": 상대가 건 연결(들어온 연결)이 남아야 한다.
        manager.handle(.connected(1, route: .manual, isOutbound: true))   // 내가 건 연결
        manager.handle(.received(1, hello("aaa")))
        manager.handle(.connected(2, route: nil, isOutbound: false))      // 상대가 건 연결
        manager.handle(.received(2, hello("aaa")))

        XCTAssertEqual(manager.peers.count, 1)
        XCTAssertEqual(transport.closed, [1])
    }

    func testDuplicateKeepsOutboundWhenOwnIDIsSmaller() {
        // 상대 "zzz" > 나 "mmm": 내가 건 연결이 남아야 한다 (도착 순서와 무관).
        manager.handle(.connected(2, route: nil, isOutbound: false))
        manager.handle(.received(2, hello("zzz")))
        manager.handle(.connected(1, route: .manual, isOutbound: true))
        manager.handle(.received(1, hello("zzz")))

        XCTAssertEqual(manager.peers.count, 1)
        XCTAssertEqual(transport.closed, [2])
    }

    func testDuplicateLosingConnectionArrivingSecondIsDropped() {
        manager.handle(.connected(1, route: nil, isOutbound: false))      // 상대("aaa")가 건 연결 = 승자
        manager.handle(.received(1, hello("aaa")))
        manager.handle(.connected(2, route: .manual, isOutbound: true))   // 내가 건 연결 = 패자
        manager.handle(.received(2, hello("aaa")))

        XCTAssertEqual(manager.peers.count, 1)
        XCTAssertEqual(transport.closed, [2])
        // 패자 연결의 뒤늦은 disconnected 이벤트가 승자 피어를 지우면 안 된다.
        manager.handle(.disconnected(2))
        XCTAssertEqual(manager.peers.count, 1)
    }

    func testSameDialerDuplicateReplacesStaleConnection() {
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, hello("aaa")))
        manager.handle(.connected(2, route: nil, isOutbound: false))
        manager.handle(.received(2, hello("aaa")))
        XCTAssertEqual(manager.peers.count, 1)
        XCTAssertEqual(transport.closed, [1])
    }

    // MARK: input / session 전달

    func testInputAndSessionAreDeliveredFromHelloedPeer() {
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, hello("aaa")))
        manager.handle(.received(1, PeerCodec.encode(.input(deviceID: "aaa", sourceID: "com.apple.keylayout.2SetKorean", isKorean: true))))
        manager.handle(.received(1, PeerCodec.encode(.session(deviceID: "aaa", active: true))))
        XCTAssertEqual(received.map(\.0), [
            .input(deviceID: "aaa", sourceID: "com.apple.keylayout.2SetKorean", isKorean: true),
            .session(deviceID: "aaa", active: true),
        ])
        XCTAssertEqual(received.first?.1.name, "상대")
    }

    func testMessagesBeforeHelloOrWithSpoofedDeviceIDAreIgnored() {
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, PeerCodec.encode(.session(deviceID: "aaa", active: true))))
        manager.handle(.received(1, hello("aaa")))
        manager.handle(.received(1, PeerCodec.encode(.session(deviceID: "bbb", active: true))))
        XCTAssertTrue(received.isEmpty)
    }

    func testBroadcastGoesOnlyToHelloedPeers() {
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, hello("aaa")))
        manager.handle(.connected(2, route: nil, isOutbound: false)) // hello 전
        transport.clearSent()
        manager.broadcast(.session(deviceID: me, active: true))
        XCTAssertEqual(transport.messages(to: 1), [.session(deviceID: me, active: true)])
        XCTAssertTrue(transport.messages(to: 2).isEmpty)
    }

    // MARK: 분할/병합, 크기·빈도 제한

    func testSplitAndMergedChunksAreDecoded() {
        manager.handle(.connected(1, route: nil, isOutbound: false))
        let first = hello("aaa")
        let second = PeerCodec.encode(.session(deviceID: "aaa", active: true))
        let all = first + second
        // 임의 지점에서 쪼갠 두 덩어리 (첫 메시지 중간 / 둘째 메시지 중간).
        let cut1 = 7, cut2 = first.count + 5
        manager.handle(.received(1, all.subdata(in: 0..<cut1)))
        manager.handle(.received(1, all.subdata(in: cut1..<cut2)))
        manager.handle(.received(1, all.subdata(in: cut2..<all.count)))
        XCTAssertEqual(manager.peers.count, 1)
        XCTAssertEqual(received.count, 1)
    }

    func testOversizedMessageIsIgnoredAndConnectionSurvives() {
        var limits = PeerManager.Limits()
        limits.maxMessageBytes = 200
        makeManager(limits: limits)
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, hello("aaa")))
        let huge = PeerCodec.encode(.input(deviceID: "aaa", sourceID: String(repeating: "x", count: 500), isKorean: true))
        manager.handle(.received(1, huge))
        manager.handle(.received(1, PeerCodec.encode(.session(deviceID: "aaa", active: true))))
        XCTAssertEqual(received.map(\.0), [.session(deviceID: "aaa", active: true)])
    }

    func testMessagesOverRateLimitAreIgnoredUntilWindowPasses() {
        var limits = PeerManager.Limits()
        limits.maxMessagesPerWindow = 3
        limits.window = 1
        makeManager(limits: limits)
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, hello("aaa")))                       // 1
        for _ in 0..<5 {
            manager.handle(.received(1, PeerCodec.encode(.session(deviceID: "aaa", active: true))))
        }
        XCTAssertEqual(received.count, 2)                                // 한도 3 중 hello 제외 2개만 통과
        clock.advance(by: 1.5)
        manager.handle(.received(1, PeerCodec.encode(.session(deviceID: "aaa", active: false))))
        XCTAssertEqual(received.count, 3)
    }

    func testGarbageLinesAreIgnored() {
        manager.handle(.connected(1, route: nil, isOutbound: false))
        manager.handle(.received(1, Data("not json\n{\"type\":\"nope\",\"deviceID\":\"a\"}\n".utf8)))
        manager.handle(.received(1, hello("aaa")))
        XCTAssertEqual(manager.peers.count, 1)
        XCTAssertGreaterThanOrEqual(manager.ignoredMessageCount, 2)
    }

    // MARK: 설정

    func testSavePairingStoresAndPushesConfig() {
        manager.savePairing(passphrase: "비밀", manualAddress: " 100.64.0.2 ")
        XCTAssertEqual(stores.passphrase, "비밀")
        XCTAssertEqual(stores.manualPeerAddress, "100.64.0.2")
        XCTAssertEqual(transport.configs.last, PeerTransportConfig(passphrase: "비밀", manualAddress: "100.64.0.2"))

        manager.savePairing(passphrase: "", manualAddress: "")
        XCTAssertNil(stores.passphrase)
        XCTAssertEqual(transport.configs.last, PeerTransportConfig(passphrase: "", manualAddress: nil))
    }
}
