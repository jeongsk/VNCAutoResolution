import XCTest
@testable import VNCAutoResolutionCore

/// 입력 동기화 규칙 (가짜 포트 + FakeClock). 피어 쪽은 FakePeerTransport로 보낸 메시지를 확인한다.
final class InputSyncTests: XCTestCase {
    private var vnc: FakeVNCDetector!
    private var input: FakeInputSource!
    private var viewers: FakeViewerApps!
    private var transport: FakePeerTransport!
    private var syncSettings: InMemoryInputSyncSettings!
    private var clock: FakeClock!
    private var core: AppCore!

    private let me = "mmm"
    private let peerID = "aaa"
    private var sync: InputSyncController { core.inputSync }

    override func setUp() {
        vnc = FakeVNCDetector()
        input = FakeInputSource()
        viewers = FakeViewerApps()
        transport = FakePeerTransport()
        syncSettings = InMemoryInputSyncSettings()
        clock = FakeClock()
        makeCore()
        connectPeer()
    }

    private func makeCore() {
        core = AppCore(
            vnc: vnc, display: FakeDisplay(), settings: FakeSettingsStore(), clock: clock,
            peerTransport: transport, peerSettings: InMemoryPeerStores(deviceID: me),
            inputSource: input, viewerApps: viewers, inputSyncSettings: syncSettings)
    }

    private func connectPeer() {
        core.peers.handle(.connected(1, route: .manual, isOutbound: true))
        core.peers.handle(.received(1, PeerCodec.encode(
            .hello(deviceID: peerID, name: "상대", protocolVersion: 1, route: nil))))
        transport.clearSent()
    }

    /// 피어에게 보낸 (hello 제외) 메시지.
    private var sent: [PeerMessage] {
        transport.messages(to: 1).filter { if case .hello = $0 { return false } else { return true } }
    }

    private func receive(_ message: PeerMessage) {
        core.peers.handle(.received(1, PeerCodec.encode(message)))
    }

    private func startViewer() {
        viewers.runningBundleIDs = ["com.apple.finder", "com.apple.ScreenSharing"]
        sync.viewerAppsChanged()
    }

    /// 로컬에서 사용자가 입력 소스를 바꿈.
    private func userSwitches(to state: InputState) {
        input.current = state
        sync.localInputChanged()
    }

    private func inputMessage(_ s: InputState) -> PeerMessage {
        .input(deviceID: me, sourceID: s.id, isKorean: s.isKorean)
    }

    // MARK: 보내기

    func testLocalChangeSendsAbsoluteState() {
        startViewer()
        transport.clearSent()
        userSwitches(to: FakeInputSource.dubeolsik)
        XCTAssertEqual(sent, [inputMessage(FakeInputSource.dubeolsik)])
    }

    func testSameStateIsNotSentTwice() {
        startViewer()
        transport.clearSent()
        userSwitches(to: FakeInputSource.dubeolsik)
        sync.localInputChanged()
        XCTAssertEqual(sent.count, 1)
    }

    // MARK: 받기 / 대체 선택

    func testReceivedStateIsAppliedAndNotEchoed() {
        startViewer()
        transport.clearSent()
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.dubeolsik.id, isKorean: true))
        XCTAssertEqual(input.selected, [FakeInputSource.dubeolsik.id])
        // 적용 직후 도착한 로컬 변경 알림은 에코
        sync.localInputChanged()
        XCTAssertEqual(sent, [])
    }

    func testReceivedStateEqualToCurrentIsNotApplied() {
        startViewer()
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.abc.id, isKorean: false))
        XCTAssertEqual(input.selected, [])
    }

    func testFallbackKoreanWhenExactIDMissingAppliesLocalKorean() {
        startViewer()
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.gureum.id, isKorean: true))
        XCTAssertEqual(input.selected, [FakeInputSource.dubeolsik.id])
    }

    func testFallbackEnglishToABC() {
        startViewer()
        input.current = FakeInputSource.dubeolsik
        receive(.input(deviceID: peerID, sourceID: "com.example.dvorak", isKorean: false))
        XCTAssertEqual(input.selected, [FakeInputSource.abc.id])
    }

    func testSelectorRules() {
        let all = [FakeInputSource.us, FakeInputSource.gureum, FakeInputSource.dubeolsik, FakeInputSource.abc]
        // 정확한 ID 우선
        XCTAssertEqual(InputSourceSelector.select(id: FakeInputSource.dubeolsik.id, isKorean: true, from: all), FakeInputSource.dubeolsik)
        // 한국어: 첫 한국어 입력기
        XCTAssertEqual(InputSourceSelector.select(id: "x", isKorean: true, from: all), FakeInputSource.gureum)
        // 영문: ABC 우선 (US가 앞에 있어도)
        XCTAssertEqual(InputSourceSelector.select(id: "x", isKorean: false, from: all), FakeInputSource.abc)
        // ABC 없으면 첫 비한국어
        XCTAssertEqual(InputSourceSelector.select(id: "x", isKorean: false, from: [FakeInputSource.gureum, FakeInputSource.us]), FakeInputSource.us)
        // 해당 언어가 없으면 nil
        XCTAssertNil(InputSourceSelector.select(id: "x", isKorean: true, from: [FakeInputSource.abc]))
        XCTAssertNil(InputSourceSelector.select(id: "x", isKorean: false, from: [FakeInputSource.dubeolsik]))
    }

    func testNoMatchingSourceReportsMessage() {
        startViewer()
        input.available = [FakeInputSource.abc]
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.dubeolsik.id, isKorean: true))
        XCTAssertEqual(input.selected, [])
        XCTAssertTrue(sync.lastMessage.hasPrefix("입력 소스 적용 실패"))
    }

    // MARK: 에코 억제

    func testDifferentIDFastAfterApplyIsPropagated() {
        startViewer()
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.dubeolsik.id, isKorean: true))
        transport.clearSent()
        clock.advance(by: 0.2)   // 유효시간(1초) 안
        userSwitches(to: FakeInputSource.us)
        XCTAssertEqual(sent, [inputMessage(FakeInputSource.us)])
    }

    func testSameIDAfterAppliedWindowStillNotResent() {
        startViewer()
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.dubeolsik.id, isKorean: true))
        clock.advance(by: 5)
        transport.clearSent()
        sync.localInputChanged()
        XCTAssertEqual(sent, [])
    }

    func testSwitchingBackToAppliedIDAfterRealSwitchIsPropagated() {
        startViewer()
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.dubeolsik.id, isKorean: true))
        userSwitches(to: FakeInputSource.us)
        transport.clearSent()
        userSwitches(to: FakeInputSource.dubeolsik)   // 창 안이지만 실제 전환
        XCTAssertEqual(sent, [inputMessage(FakeInputSource.dubeolsik)])
    }

    // MARK: 세션 게이트

    func testWaitingWithoutSessionIgnoresBothDirections() {
        XCTAssertEqual(sync.status, .waiting)
        userSwitches(to: FakeInputSource.dubeolsik)
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.us.id, isKorean: false))
        XCTAssertEqual(sent, [])
        XCTAssertEqual(input.selected, [])
    }

    func testLocalVNCOpensGate() {
        vnc.clients = ["10.0.0.2"]
        core.tick()
        XCTAssertEqual(sync.status, .active)
        transport.clearSent()
        userSwitches(to: FakeInputSource.dubeolsik)
        XCTAssertEqual(sent, [inputMessage(FakeInputSource.dubeolsik)])
    }

    func testViewerAppOpensGateAndPrefixMatches() {
        viewers.runningBundleIDs = ["com.edovia.screens5.mac"]
        sync.viewerAppsChanged()
        XCTAssertEqual(sync.status, .active)
        viewers.runningBundleIDs = []
        sync.viewerAppsChanged()
        XCTAssertEqual(sync.status, .waiting)
    }

    func testPeerSessionSignalOpensGateUntilTTL() {
        receive(.session(deviceID: peerID, active: true))
        XCTAssertEqual(sync.status, .active)
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.dubeolsik.id, isKorean: true))
        XCTAssertEqual(input.selected, [FakeInputSource.dubeolsik.id])

        clock.advance(by: sync.sessionTTL - 1)
        XCTAssertEqual(sync.status, .active)
        clock.advance(by: 2)
        XCTAssertEqual(sync.status, .waiting)
        input.selected.removeAll()
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.us.id, isKorean: false))
        XCTAssertEqual(input.selected, [])
    }

    func testPeerSessionRefreshExtendsTTLAndInactiveClosesGate() {
        receive(.session(deviceID: peerID, active: true))
        clock.advance(by: 400)
        receive(.session(deviceID: peerID, active: true))
        clock.advance(by: 400)
        XCTAssertEqual(sync.status, .active)
        receive(.session(deviceID: peerID, active: false))
        XCTAssertEqual(sync.status, .waiting)
    }

    func testAlwaysSyncIgnoresSessionCondition() {
        core.inputSync.onlyDuringRemote = false
        XCTAssertEqual(sync.status, .active)
        userSwitches(to: FakeInputSource.dubeolsik)
        XCTAssertEqual(sent, [inputMessage(FakeInputSource.dubeolsik)])
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.us.id, isKorean: false))
        XCTAssertEqual(input.selected, [FakeInputSource.us.id])
    }

    // MARK: 세션 시작 / 유지

    func testSessionStartAnnouncesAndSendsStateOnce() {
        input.current = FakeInputSource.dubeolsik
        startViewer()
        XCTAssertEqual(sent, [
            .session(deviceID: me, active: true),
            inputMessage(FakeInputSource.dubeolsik),
        ])
        transport.clearSent()
        sync.viewerAppsChanged()   // 이미 시작됨 → 다시 보내지 않음
        core.tick()
        XCTAssertEqual(sent, [])
    }

    func testSessionEndAnnouncesInactive() {
        startViewer()
        transport.clearSent()
        viewers.runningBundleIDs = []
        sync.viewerAppsChanged()
        XCTAssertEqual(sent, [.session(deviceID: me, active: false)])
    }

    func testSessionSignalIsResentPeriodically() {
        startViewer()
        transport.clearSent()
        clock.advance(by: sync.sessionRefresh - 1)
        core.tick()
        XCTAssertEqual(sent, [])
        clock.advance(by: 2)
        core.tick()
        XCTAssertEqual(sent, [.session(deviceID: me, active: true)])
        transport.clearSent()
        core.tick()
        XCTAssertEqual(sent, [])
    }

    func testHostWithVNCDoesNotOverrideViewerSideState() {
        // 상대(뷰어 쪽)가 먼저 세션을 알렸다면, VNC만 있는 호스트는 자기 상태를 밀어 넣지 않는다.
        receive(.session(deviceID: peerID, active: true))
        transport.clearSent()
        vnc.clients = ["10.0.0.2"]
        core.tick()
        XCTAssertEqual(sent, [.session(deviceID: me, active: true)])
    }

    func testNewPeerDuringSessionGetsSessionAndState() {
        startViewer()
        core.peers.handle(.disconnected(1))
        transport.clearSent()
        core.peers.handle(.connected(2, route: .manual, isOutbound: true))
        core.peers.handle(.received(2, PeerCodec.encode(
            .hello(deviceID: "bbb", name: "새 맥", protocolVersion: 1, route: nil))))
        let toNew = transport.messages(to: 2).filter { if case .hello = $0 { return false } else { return true } }
        XCTAssertEqual(toNew, [.session(deviceID: me, active: true), inputMessage(FakeInputSource.abc)])
    }

    // MARK: 일시정지 / 설정

    func testPauseStopsSendAndApply() {
        startViewer()
        transport.clearSent()
        sync.enabled = false
        XCTAssertEqual(sync.status, .paused)
        userSwitches(to: FakeInputSource.dubeolsik)
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.us.id, isKorean: false))
        XCTAssertEqual(sent, [])
        XCTAssertEqual(input.selected, [])

        sync.enabled = true
        XCTAssertEqual(sync.status, .active)
        userSwitches(to: FakeInputSource.us)
        XCTAssertEqual(sent, [inputMessage(FakeInputSource.us)])
    }

    func testSettingsArePersistedThroughStore() {
        sync.enabled = false
        sync.onlyDuringRemote = false
        XCTAssertFalse(syncSettings.inputSyncEnabled)
        XCTAssertFalse(syncSettings.inputSyncOnlyDuringRemote)
        makeCore()
        XCTAssertFalse(sync.enabled)
        XCTAssertFalse(sync.onlyDuringRemote)
    }

    // MARK: 적용 재확인 / 재시도

    func testApplyIsRetriedWhenNotReflected() {
        startViewer()
        input.failuresBeforeSuccess = 2
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.dubeolsik.id, isKorean: true))
        XCTAssertEqual(input.selected.count, 3)
        XCTAssertEqual(input.current, FakeInputSource.dubeolsik)
        XCTAssertEqual(sync.lastMessage, "")
    }

    func testApplyGivesUpAfterMaxAttempts() {
        startViewer()
        input.failuresBeforeSuccess = 10
        receive(.input(deviceID: peerID, sourceID: FakeInputSource.dubeolsik.id, isKorean: true))
        XCTAssertEqual(input.selected.count, sync.maxApplyAttempts)
        XCTAssertTrue(sync.lastMessage.hasPrefix("입력 소스 적용 실패"))
    }

    func testStateChangeCallbackFires() {
        var count = 0
        core.onStateChange = { count += 1 }
        receive(.session(deviceID: peerID, active: true))
        XCTAssertGreaterThan(count, 0)
    }
}
