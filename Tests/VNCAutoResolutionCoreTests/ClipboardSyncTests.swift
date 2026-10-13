import XCTest
@testable import VNCAutoResolutionCore

/// 텍스트 클립보드 공유 규칙 (가짜 포트 + FakeClock). 피어 쪽은 FakePeerTransport로 보낸 메시지를 확인한다.
final class ClipboardSyncTests: XCTestCase {
    private var vnc: FakeVNCDetector!
    private var viewers: FakeViewerApps!
    private var transport: FakePeerTransport!
    private var clipboard: FakeClipboard!
    private var settings: InMemoryClipboardSettings!
    private var inputSyncSettings: InMemoryInputSyncSettings!
    private var clock: FakeClock!
    private var core: AppCore!

    private let me = "mmm"
    private let peerID = "aaa"
    private var sync: ClipboardSyncController { core.clipboardSync }

    override func setUp() {
        vnc = FakeVNCDetector()
        viewers = FakeViewerApps()
        transport = FakePeerTransport()
        clipboard = FakeClipboard()
        settings = InMemoryClipboardSettings()
        settings.clipboardSyncEnabled = true
        inputSyncSettings = InMemoryInputSyncSettings()
        clock = FakeClock()
        core = AppCore(
            vnc: vnc, display: FakeDisplay(), settings: FakeSettingsStore(), clock: clock,
            peerTransport: transport, peerSettings: InMemoryPeerStores(deviceID: me),
            viewerApps: viewers, inputSyncSettings: inputSyncSettings,
            clipboard: clipboard, clipboardSettings: settings)
        connectPeer()
    }

    private func connectPeer(id: PeerConnectionID = 1, deviceID: String? = nil, features: [String] = ["clipboard"]) {
        core.peers.handle(.connected(id, route: .manual, isOutbound: true))
        core.peers.handle(.received(id, PeerCodec.encode(
            .hello(deviceID: deviceID ?? peerID, name: "상대", protocolVersion: 1, route: nil, features: features))))
        transport.clearSent()
    }

    /// 연결 `id`로 보낸 클립보드 메시지.
    private func sentClipboard(to id: PeerConnectionID = 1) -> [PeerMessage] {
        transport.messages(to: id).filter { if case .clipboard = $0 { return true } else { return false } }
    }

    private func receive(_ text: String, on id: PeerConnectionID = 1, from deviceID: String? = nil) {
        core.peers.handle(.received(id, PeerCodec.encode(.clipboard(deviceID: deviceID ?? peerID, text: text))))
    }

    private func startViewer() {
        viewers.runningBundleIDs = ["com.apple.ScreenSharing"]
        core.inputSync.viewerAppsChanged()
    }

    private func copy(_ text: String, types: [String] = ["public.utf8-plain-text"]) {
        clipboard.userCopies(text, types: types)
        sync.poll()
    }

    // MARK: 기본값

    func testDisabledByDefault() {
        XCTAssertFalse(InMemoryClipboardSettings().clipboardSyncEnabled)
    }

    // MARK: 보내기

    func testCopyDuringSessionSendsText() {
        startViewer()
        copy("안녕")
        XCTAssertEqual(sentClipboard(), [.clipboard(deviceID: me, text: "안녕")])
        XCTAssertEqual(sync.lastStatus, .sent)
    }

    func testUnchangedClipboardIsNotSentAgain() {
        startViewer()
        copy("안녕")
        sync.poll()
        sync.poll()
        XCTAssertEqual(sentClipboard().count, 1)
    }

    func testDisabledDoesNotSend() {
        settings.clipboardSyncEnabled = false
        startViewer()
        copy("안녕")
        XCTAssertEqual(sentClipboard(), [])
        XCTAssertEqual(sync.lastStatus, .none)
    }

    func testNonTextIsIgnored() {
        startViewer()
        clipboard.userCopiesNonText()
        sync.poll()
        XCTAssertEqual(sentClipboard(), [])
        XCTAssertEqual(sync.lastStatus, .none)
    }

    func testClipboardBeforeEnablingIsNotSent() {
        settings.clipboardSyncEnabled = false
        startViewer()
        copy("켜기 전")
        sync.enabled = true
        sync.poll()
        XCTAssertEqual(sentClipboard(), [])
    }

    // MARK: 세션 게이트

    func testNoSessionDoesNotSend() {
        copy("안녕")
        XCTAssertEqual(sentClipboard(), [])
        XCTAssertEqual(sync.lastStatus, .skipped(.noSession))
    }

    func testClipboardCopiedBeforeSessionIsNotSentWhenSessionStarts() {
        copy("세션 전")
        startViewer()
        sync.poll()
        XCTAssertEqual(sentClipboard(), [])
    }

    func testPeerSessionSignalOpensGate() {
        core.peers.handle(.received(1, PeerCodec.encode(.session(deviceID: peerID, active: true))))
        copy("안녕")
        XCTAssertEqual(sentClipboard().count, 1)
    }

    func testExpiredPeerSessionClosesGate() {
        core.peers.handle(.received(1, PeerCodec.encode(.session(deviceID: peerID, active: true))))
        clock.advance(by: core.inputSync.sessionTTL + 1)
        copy("안녕")
        XCTAssertEqual(sentClipboard(), [])
        receive("받음")
        XCTAssertEqual(clipboard.written, [])
    }

    func testInputSyncPauseDoesNotAffectClipboard() {
        inputSyncSettings.inputSyncEnabled = false
        startViewer()
        copy("안녕")
        XCTAssertEqual(sentClipboard().count, 1)
    }

    func testInputSyncAlwaysModeDoesNotOpenGate() {
        inputSyncSettings.inputSyncOnlyDuringRemote = false
        copy("안녕")
        XCTAssertEqual(sentClipboard(), [])
    }

    // MARK: 크기·숨김 항목

    func testTextAtLimitIsSentAndArrivesThroughPeerManager() {
        startViewer()
        // 이스케이프가 가장 많이 붙는 문자(제어 문자는 \u00XX로 6바이트)로 상한을 꽉 채운다.
        let text = String(repeating: "\u{01}", count: ClipboardSyncController.maxTextBytes)
        transport.clearSent()   // 세션 신호 제외
        copy(text)
        let sent = transport.sent.filter { $0.id == 1 }.map(\.data)
        XCTAssertEqual(sent.count, 1)

        // 같은 버전의 상대가 그 줄을 그대로 받아 적용한다.
        let other = FakeClipboard()
        let otherSettings = InMemoryClipboardSettings()
        otherSettings.clipboardSyncEnabled = true
        let otherViewers = FakeViewerApps()
        otherViewers.runningBundleIDs = ["com.apple.ScreenSharing"]
        let receiver = AppCore(
            vnc: FakeVNCDetector(), display: FakeDisplay(), settings: FakeSettingsStore(), clock: clock,
            peerTransport: FakePeerTransport(), peerSettings: InMemoryPeerStores(deviceID: peerID),
            viewerApps: otherViewers, clipboard: other, clipboardSettings: otherSettings)
        receiver.inputSync.viewerAppsChanged()
        receiver.peers.handle(.connected(9, route: .manual, isOutbound: false))
        receiver.peers.handle(.received(9, PeerCodec.encode(
            .hello(deviceID: me, name: "나", protocolVersion: 1, route: nil, features: ["clipboard"]))))
        receiver.peers.handle(.received(9, sent[0]))
        XCTAssertTrue(other.written == [text], "상한 크기의 텍스트가 상대에게 적용돼야 한다")
    }

    func testTextOverLimitIsSkipped() {
        startViewer()
        copy(String(repeating: "a", count: ClipboardSyncController.maxTextBytes + 1))
        XCTAssertEqual(sentClipboard(), [])
        XCTAssertEqual(sync.lastStatus, .skipped(.tooLarge))
    }

    func testLimitCountsUTF8Bytes() {
        startViewer()
        // 한글은 UTF-8로 3바이트다.
        copy(String(repeating: "가", count: ClipboardSyncController.maxTextBytes / 3 + 1))
        XCTAssertEqual(sync.lastStatus, .skipped(.tooLarge))
    }

    func testConcealedTransientAndAutoGeneratedAreSkipped() {
        startViewer()
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            copy("비밀", types: ["public.utf8-plain-text", marker])
            XCTAssertEqual(sync.lastStatus, .skipped(.concealed), marker)
        }
        XCTAssertEqual(sentClipboard(), [])
    }

    // MARK: 상대 기능

    func testPeerWithoutClipboardFeatureIsNotSentTo() {
        connectPeer(id: 2, deviceID: "bbb", features: [])
        startViewer()
        copy("안녕")
        XCTAssertEqual(sentClipboard(to: 1).count, 1)
        XCTAssertEqual(sentClipboard(to: 2), [])
    }

    func testOnlyOldPeersMeansNeedsUpdate() {
        core.peers.handle(.disconnected(1))
        connectPeer(id: 2, deviceID: "bbb", features: [])
        XCTAssertEqual(sync.peerSupport, .needsUpdate)
        startViewer()
        copy("안녕")
        XCTAssertEqual(sentClipboard(to: 2), [])
        XCTAssertEqual(sync.lastStatus, .skipped(.peerNeedsUpdate))
    }

    func testPeerSupportStates() {
        XCTAssertEqual(sync.peerSupport, .supported)
        core.peers.handle(.disconnected(1))
        XCTAssertEqual(sync.peerSupport, .noPeers)
    }

    // MARK: 받기 / 에코 억제

    func testReceivedTextIsAppliedAndNotEchoed() {
        startViewer()
        receive("받은 글")
        XCTAssertEqual(clipboard.written, ["받은 글"])
        XCTAssertEqual(sync.lastStatus, .received)
        sync.poll()
        XCTAssertEqual(sentClipboard(), [])
    }

    func testLocalCopyAfterReceiveIsSent() {
        startViewer()
        receive("받은 글")
        sync.poll()
        copy("새 글")
        XCTAssertEqual(sentClipboard(), [.clipboard(deviceID: me, text: "새 글")])
    }

    func testReceiveWithoutSessionIsNotApplied() {
        receive("받은 글")
        XCTAssertEqual(clipboard.written, [])
    }

    func testReceiverToggleOffIsNotApplied() {
        settings.clipboardSyncEnabled = false
        startViewer()
        receive("받은 글")
        XCTAssertEqual(clipboard.written, [])
    }

    func testReceivedOverLimitIsNotApplied() {
        startViewer()
        receive(String(repeating: "a", count: ClipboardSyncController.maxTextBytes + 1))
        XCTAssertEqual(clipboard.written, [])
    }

    func testSpoofedDeviceIDIsIgnored() {
        startViewer()
        receive("위장", from: "zzz")
        XCTAssertEqual(clipboard.written, [])
    }

    // MARK: 줄 상한

    func testOversizedLineIsDroppedAndConnectionKept() {
        let limit = PeerManager.Limits().maxMessageBytes
        core.peers.handle(.received(1, Data(repeating: 0x61, count: limit + 1) + Data([0x0A])))
        XCTAssertEqual(core.peers.peers.map(\.deviceID), [peerID])
        startViewer()
        receive("다음 줄")
        XCTAssertEqual(clipboard.written, ["다음 줄"])
    }
}
