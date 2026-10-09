import XCTest
@testable import VNCAutoResolutionCore

/// 클라이언트 화면 정보(display) 송수신 규칙 (가짜 포트 + FakeClock).
final class ClientDisplayTests: XCTestCase {
    private var viewers: FakeViewerApps!
    private var transport: FakePeerTransport!
    private var screen: FakeScreen!
    private var clock: FakeClock!
    private var core: AppCore!
    private var changeCount = 0

    private let me = "mmm"
    private let peerID = "aaa"

    override func setUp() {
        viewers = FakeViewerApps()
        transport = FakePeerTransport()
        screen = FakeScreen()
        clock = FakeClock()
        changeCount = 0
        core = AppCore(
            vnc: FakeVNCDetector(), display: FakeDisplay(), settings: FakeSettingsStore(), clock: clock,
            peerTransport: transport, peerSettings: InMemoryPeerStores(deviceID: me),
            inputSource: FakeInputSource(), viewerApps: viewers, screen: screen)
        core.onClientDisplayChange = { [unowned self] in changeCount += 1 }
    }

    private func connectPeer(id: PeerConnectionID = 1, deviceID: String? = nil) {
        core.peers.handle(.connected(id, route: .manual, isOutbound: true))
        core.peers.handle(.received(id, PeerCodec.encode(
            .hello(deviceID: deviceID ?? peerID, name: "상대", protocolVersion: 1, route: nil))))
        transport.clearSent()
    }

    private func receive(_ message: PeerMessage, on id: PeerConnectionID = 1) {
        core.peers.handle(.received(id, PeerCodec.encode(message)))
    }

    private func displays(sentTo id: PeerConnectionID = 1) -> [PeerMessage] {
        transport.messages(to: id).filter { if case .display = $0 { return true } else { return false } }
    }

    private func startViewer() {
        viewers.runningBundleIDs = ["com.apple.ScreenSharing"]
        core.inputSync.viewerAppsChanged()
    }

    private func display(_ w: Int = 1512, _ h: Int = 982, _ s: Double = 2, from id: String? = nil) -> PeerMessage {
        .display(deviceID: id ?? peerID, width: w, height: h, scale: s)
    }

    private var myDisplay: PeerMessage { .display(deviceID: me, width: 1512, height: 982, scale: 2) }

    // MARK: 코덱

    func testDisplayRoundTripsAndWireFormat() {
        let message = PeerMessage.display(deviceID: "a", width: 1512, height: 982, scale: 2)
        XCTAssertEqual(PeerCodec.decode(PeerCodec.encode(message).dropLast()), message)
        let line = #"{"type":"display","deviceID":"a","width":1440,"height":900,"scale":1.5}"#
        XCTAssertEqual(PeerCodec.decode(Data(line.utf8)), .display(deviceID: "a", width: 1440, height: 900, scale: 1.5))
    }

    func testUnknownMessageTypeIsIgnoredAndConnectionKept() {
        connectPeer()
        receive(.session(deviceID: peerID, active: true))
        let unknown = Data(#"{"type":"future","deviceID":"aaa","x":1}"#.utf8) + [0x0A]
        // 모르는 종류 + 뒤따르는 정상 메시지가 한 번에 와도 정상 메시지는 처리된다.
        core.peers.handle(.received(1, unknown + PeerCodec.encode(display())))
        XCTAssertEqual(core.peers.peers.map(\.deviceID), [peerID])
        XCTAssertTrue(transport.closed.isEmpty)
        XCTAssertEqual(core.peers.ignoredMessageCount, 1)
        XCTAssertEqual(core.clientDisplay?.width, 1512)
    }

    // MARK: 송신 (뷰어 쪽만)

    func testViewerSideSendsOnSessionStart() {
        connectPeer()
        startViewer()
        XCTAssertEqual(displays(), [myDisplay])
    }

    func testViewerSideSendsToNewPeer() {
        startViewer()
        connectPeer()
        XCTAssertEqual(displays(), [], "clearSent 이후에는 비어 있어야 한다")
        core.peers.handle(.connected(2, route: .manual, isOutbound: true))
        core.peers.handle(.received(2, PeerCodec.encode(
            .hello(deviceID: "bbb", name: "셋째", protocolVersion: 1, route: nil))))
        XCTAssertEqual(displays(sentTo: 2), [myDisplay])
    }

    func testViewerSideSendsOnScreenConfigurationChange() {
        connectPeer()
        startViewer()
        transport.clearSent()
        screen.mainScreen = ScreenInfo(width: 1728, height: 1117, scale: 2)
        core.screenConfigurationChanged()
        XCTAssertEqual(displays(), [.display(deviceID: me, width: 1728, height: 1117, scale: 2)])
    }

    func testNonViewerSideNeverSends() {
        connectPeer()
        core.handle(clients: ["192.168.0.5"])   // 호스트: 로컬 VNC 세션만 있다
        core.screenConfigurationChanged()
        connectPeer(id: 2, deviceID: "bbb")
        XCTAssertTrue(displays().isEmpty)
        XCTAssertTrue(displays(sentTo: 2).isEmpty)
    }

    func testNothingSentWhenScreenUnreadable() {
        connectPeer()
        screen.mainScreen = nil
        startViewer()
        XCTAssertTrue(displays().isEmpty)
    }

    // MARK: 수신 (호스트)

    func testDisplayIgnoredUntilPeerSessionActive() {
        connectPeer()
        receive(display())
        XCTAssertNil(core.clientDisplay)
        receive(.session(deviceID: peerID, active: true))
        XCTAssertEqual(core.clientDisplay, ClientDisplay(deviceID: peerID, width: 1512, height: 982, scale: 2))
        XCTAssertEqual(changeCount, 1)
    }

    func testLatestDisplayWins() {
        connectPeer()
        receive(.session(deviceID: peerID, active: true))
        receive(display(1512, 982, 2))
        receive(display(1728, 1117, 2))
        XCTAssertEqual(core.clientDisplay?.width, 1728)
        receive(display(1728, 1117, 2))   // 같은 값이면 알리지 않는다
        XCTAssertEqual(changeCount, 2)
    }

    func testClearedWhenSessionSignalExpires() {
        connectPeer()
        receive(.session(deviceID: peerID, active: true))
        receive(display())
        clock.advance(by: core.inputSync.sessionTTL + 1)
        core.handle(clients: [])   // tick이 만료를 정리한다
        XCTAssertNil(core.clientDisplay)
        XCTAssertEqual(changeCount, 2)
        // 세션이 다시 활성이 돼도 옛 화면 정보는 되살아나지 않는다.
        receive(.session(deviceID: peerID, active: true))
        XCTAssertNil(core.clientDisplay)
    }

    func testClearedWhenPeerReportsSessionInactive() {
        connectPeer()
        receive(.session(deviceID: peerID, active: true))
        receive(display())
        receive(.session(deviceID: peerID, active: false))
        XCTAssertNil(core.clientDisplay)
    }

    func testClearedOnDisconnect() {
        connectPeer()
        receive(.session(deviceID: peerID, active: true))
        receive(display())
        core.peers.handle(.disconnected(1))
        XCTAssertNil(core.clientDisplay)
        XCTAssertEqual(changeCount, 2)
    }

    func testOtherPeerDisconnectKeepsActivePeersDisplay() {
        connectPeer()
        connectPeer(id: 2, deviceID: "bbb")
        receive(.session(deviceID: peerID, active: true))
        receive(display())
        core.peers.handle(.disconnected(2))
        XCTAssertNotNil(core.clientDisplay)
    }

    func testInvalidDisplayValuesAreIgnored() {
        connectPeer()
        receive(.session(deviceID: peerID, active: true))
        for bad in [display(0, 982), display(1512, -1), display(100_000, 982), display(1512, 982, 0), display(1512, 982, .nan)] {
            core.clientDisplayController.handle(bad, from: core.peers.peers[0])
        }
        XCTAssertNil(core.clientDisplay)
    }

    func testSpoofedDeviceIDIsDropped() {
        connectPeer()
        receive(.session(deviceID: peerID, active: true))
        receive(display(from: "zzz"))
        XCTAssertNil(core.clientDisplay)
    }

    func testSizeLabel() {
        XCTAssertEqual(ClientDisplay(deviceID: "a", width: 1512, height: 982, scale: 2).sizeLabel, "1512×982 (@2x)")
        XCTAssertEqual(ClientDisplay(deviceID: "a", width: 1440, height: 900, scale: 1.5).sizeLabel, "1440×900 (@1.5x)")
    }
}
