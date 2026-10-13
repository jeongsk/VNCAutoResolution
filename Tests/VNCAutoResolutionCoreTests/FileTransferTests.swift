import CryptoKit
import XCTest
@testable import VNCAutoResolutionCore

/// 파일 전송 규칙 (가짜 포트 + FakeClock). 피어 연결은 1번, 데이터 채널은 따로 번호를 붙인다.
final class FileTransferTests: XCTestCase {
    private var transport: FakePeerTransport!
    private var reader: FakeFileReader!
    private var store: FakeFileStore!
    private var notifier: FakeFileOfferNotifier!
    private var settings: InMemoryFileTransferSettings!
    private var clock: FakeClock!
    private var core: AppCore!

    private let me = "mmm"
    private let peerID = "aaa"
    private let fileURL = URL(fileURLWithPath: "/tmp/보고서.pdf")
    private let content = Data("파일 내용\n{\"type\":\"hello\"}\n".utf8) + Data(repeating: 0x0A, count: 100)
    private var transfer: FileTransferController { core.fileTransfer }

    override func setUp() {
        transport = FakePeerTransport()
        reader = FakeFileReader()
        reader.files[fileURL.path] = content
        store = FakeFileStore()
        notifier = FakeFileOfferNotifier()
        settings = InMemoryFileTransferSettings()
        settings.fileReceiveEnabled = true
        clock = FakeClock()
        core = AppCore(
            vnc: FakeVNCDetector(), display: FakeDisplay(), settings: FakeSettingsStore(), clock: clock,
            peerTransport: transport, peerSettings: InMemoryPeerStores(deviceID: me),
            fileReader: reader, fileStore: store, fileOfferNotifier: notifier, fileTransferSettings: settings)
        core.peers.handle(.listening(4000))
        connectPeer()
    }

    private func connectPeer(id: PeerConnectionID = 1, deviceID: String? = nil,
                             features: [String] = ["clipboard", "fileTransfer"]) {
        core.peers.handle(.connected(id, route: .manual, isOutbound: true))
        core.peers.handle(.received(id, PeerCodec.encode(
            .hello(deviceID: deviceID ?? peerID, name: "상대 맥", protocolVersion: 1, route: nil, features: features))))
        transport.clearSent()
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 연결 `id`로 보낸 파일 전송 메시지(hello 제외).
    private func sent(to id: PeerConnectionID = 1) -> [PeerMessage] {
        transport.messages(to: id).filter { if case .hello = $0 { return false } else { return true } }
    }

    private func receive(_ message: PeerMessage, on id: PeerConnectionID = 1) {
        core.peers.handle(.received(id, PeerCodec.encode(message)))
    }

    // MARK: 보내기

    /// 보낸 제안의 전송 ID.
    private func sendFile() -> String? {
        transfer.send(fileAt: fileURL, to: peerID)
        guard case .fileOffer(_, let id, _, _, _)? = sent().last else { return nil }
        return id
    }

    func testSendOffersNameSizeAndHash() throws {
        let id = try XCTUnwrap(sendFile())
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(sent(), [.fileOffer(deviceID: me, transferID: id, name: "보고서.pdf",
                                           size: content.count, sha256: sha(content))])
        XCTAssertEqual(transfer.status, .waitingForAnswer(fileName: "보고서.pdf", peerName: "상대 맥"))
    }

    func testTransferIDsAreRandom() throws {
        let first = try XCTUnwrap(sendFile())
        let second = try XCTUnwrap(sendFile())
        XCTAssertNotEqual(first, second)
    }

    func testAcceptedOfferOpensDataChannelAndSendsHeaderThenBytes() throws {
        let id = try XCTUnwrap(sendFile())
        receive(.fileAnswer(deviceID: peerID, transferID: id, accepted: true, reason: nil, port: 5000))
        XCTAssertEqual(transport.dataChannelRequests.map(\.peer), [1])
        XCTAssertEqual(transport.dataChannelRequests.map(\.port), [5000])
        XCTAssertEqual(transport.dataChannelRequests.map(\.transferID), [id])
        XCTAssertEqual(transfer.status, .sending(fileName: "보고서.pdf"))

        core.peers.handle(.dataChannelOpened(7, transferID: id))
        XCTAssertEqual(transport.bytes(to: 7), PeerCodec.encode(.dataChannel(deviceID: me, transferID: id)) + content)
        // 데이터 채널은 피어 목록에 없다.
        XCTAssertEqual(core.peers.peers.map(\.deviceID), [peerID])

        core.peers.handle(.disconnected(7))
        XCTAssertEqual(transfer.status, .sent(fileName: "보고서.pdf"))
    }

    func testDeclinedOfferShowsReason() throws {
        let id = try XCTUnwrap(sendFile())
        receive(.fileAnswer(deviceID: peerID, transferID: id, accepted: false, reason: .disabled, port: nil))
        XCTAssertEqual(transfer.status, .declined(fileName: "보고서.pdf", reason: .disabled))
        XCTAssertEqual(transport.dataChannelRequests.count, 0)
    }

    func testAnswerForUnknownTransferIsIgnored() throws {
        _ = try XCTUnwrap(sendFile())
        receive(.fileAnswer(deviceID: peerID, transferID: "other", accepted: true, reason: nil, port: 5000))
        XCTAssertEqual(transport.dataChannelRequests.count, 0)
    }

    func testAnswerFromAnotherPeerIsIgnored() throws {
        connectPeer(id: 2, deviceID: "bbb")
        let id = try XCTUnwrap(sendFile())
        receive(.fileAnswer(deviceID: "bbb", transferID: id, accepted: true, reason: nil, port: 5000), on: 2)
        XCTAssertEqual(transport.dataChannelRequests.count, 0)
    }

    func testOfferGoesOnlyToChosenPeer() throws {
        connectPeer(id: 2, deviceID: "bbb")
        _ = try XCTUnwrap(sendFile())
        XCTAssertEqual(sent(to: 2), [])
    }

    func testPeerWithoutFeatureIsNotOffered() {
        core.peers.handle(.disconnected(1))
        connectPeer(id: 2, deviceID: peerID, features: ["clipboard"])
        XCTAssertFalse(transfer.canSend(to: core.peers.peers[0]))
        transfer.send(fileAt: fileURL, to: peerID)
        XCTAssertEqual(sent(to: 2), [])
        XCTAssertEqual(transfer.status, .sendFailed(fileName: "보고서.pdf", reason: .peerNeedsUpdate))
    }

    func testFileOverLimitIsBlockedBeforeOfferWithoutReading() {
        reader.sizes[fileURL.path] = FileTransferController.maxFileBytes + 1
        transfer.send(fileAt: fileURL, to: peerID)
        XCTAssertEqual(sent(), [])
        XCTAssertEqual(reader.readCount, 0)
        XCTAssertEqual(transfer.status, .sendFailed(fileName: "보고서.pdf", reason: .tooLarge))
    }

    func testUnreadableFileFails() {
        transfer.send(fileAt: URL(fileURLWithPath: "/tmp/없음.txt"), to: peerID)
        XCTAssertEqual(sent(), [])
        XCTAssertEqual(transfer.status, .sendFailed(fileName: "없음.txt", reason: .readFailed))
    }

    func testNoAnswerTimesOutOnSender() throws {
        _ = try XCTUnwrap(sendFile())
        clock.advance(by: transfer.answerTimeout + 1)
        transfer.tick()
        XCTAssertEqual(transfer.status, .waitingForAnswer(fileName: "보고서.pdf", peerName: "상대 맥"),
                       "받는 쪽의 시간 초과 거절을 먼저 기다린다")
        clock.advance(by: 30)
        transfer.tick()
        XCTAssertEqual(transfer.status, .sendFailed(fileName: "보고서.pdf", reason: .noAnswer))
    }

    func testPeerDisconnectWhileWaitingFails() throws {
        _ = try XCTUnwrap(sendFile())
        core.peers.handle(.disconnected(1))
        XCTAssertEqual(transfer.status, .sendFailed(fileName: "보고서.pdf", reason: .connectionFailed))
    }

    func testDataChannelOpenFailure() throws {
        let id = try XCTUnwrap(sendFile())
        receive(.fileAnswer(deviceID: peerID, transferID: id, accepted: true, reason: nil, port: 5000))
        core.peers.handle(.dataChannelFailed(transferID: id))
        XCTAssertEqual(transfer.status, .sendFailed(fileName: "보고서.pdf", reason: .connectionFailed))
    }

    // MARK: 받기: 제안·수락·거절·시간 초과

    private let offerID = "t-123"

    private func receiveOffer(name: String = "사진.png", data: Data? = nil, size: Int? = nil, hash: String? = nil) {
        let payload = data ?? content
        receive(.fileOffer(deviceID: peerID, transferID: offerID, name: name,
                           size: size ?? payload.count, sha256: hash ?? sha(payload)))
    }

    func testOfferIsShownInNotificationAndMenu() {
        receiveOffer()
        let offer = IncomingFileOffer(transferID: offerID, deviceID: peerID, peerName: "상대 맥",
                                      fileName: "사진.png", size: content.count)
        XCTAssertEqual(notifier.shown, [offer])
        XCTAssertEqual(transfer.incomingOffer, offer)
        XCTAssertEqual(sent(), [])
    }

    func testAcceptAnswersWithListenPort() {
        receiveOffer()
        transfer.accept(transferID: offerID)
        XCTAssertEqual(sent(), [.fileAnswer(deviceID: me, transferID: offerID, accepted: true, reason: nil, port: 4000)])
        XCTAssertNil(transfer.incomingOffer)
        XCTAssertEqual(notifier.removed, [offerID])
        XCTAssertEqual(transfer.status, .receiving(fileName: "사진.png"))
    }

    func testDeclineAnswersDeclined() {
        receiveOffer()
        transfer.decline(transferID: offerID)
        XCTAssertEqual(sent(), [.fileAnswer(deviceID: me, transferID: offerID, accepted: false, reason: .declined, port: nil)])
        XCTAssertNil(transfer.incomingOffer)
        XCTAssertEqual(notifier.removed, [offerID])
    }

    func testStaleAcceptIsIgnored() {
        receiveOffer()
        transfer.accept(transferID: "old")
        XCTAssertEqual(sent(), [])
        XCTAssertNotNil(transfer.incomingOffer)
    }

    func testUnansweredOfferIsDeclinedAfter60Seconds() {
        receiveOffer()
        clock.advance(by: 59)
        transfer.tick()
        XCTAssertNotNil(transfer.incomingOffer)
        clock.advance(by: 2)
        transfer.tick()
        XCTAssertEqual(sent(), [.fileAnswer(deviceID: me, transferID: offerID, accepted: false, reason: .timeout, port: nil)])
        XCTAssertNil(transfer.incomingOffer)
        XCTAssertEqual(notifier.removed, [offerID])
        XCTAssertEqual(transfer.status, .receiveFailed(fileName: "사진.png", reason: .timedOut))
    }

    func testReceiveDisabledDeclinesWithoutAsking() {
        settings.fileReceiveEnabled = false
        receiveOffer()
        XCTAssertEqual(sent(), [.fileAnswer(deviceID: me, transferID: offerID, accepted: false, reason: .disabled, port: nil)])
        XCTAssertEqual(notifier.shown, [])
    }

    func testOfferOverLimitIsDeclined() {
        receiveOffer(size: FileTransferController.maxFileBytes + 1, hash: "00")
        XCTAssertEqual(sent(), [.fileAnswer(deviceID: me, transferID: offerID, accepted: false, reason: .tooLarge, port: nil)])
        XCTAssertEqual(notifier.shown, [])
    }

    func testSecondOfferWhilePendingIsBusy() {
        receiveOffer()
        receive(.fileOffer(deviceID: peerID, transferID: "t-2", name: "b", size: 1, sha256: "00"))
        XCTAssertEqual(sent(), [.fileAnswer(deviceID: me, transferID: "t-2", accepted: false, reason: .busy, port: nil)])
        XCTAssertEqual(transfer.incomingOffer?.transferID, offerID)
    }

    func testPeerDisconnectClearsPendingOffer() {
        receiveOffer()
        core.peers.handle(.disconnected(1))
        XCTAssertNil(transfer.incomingOffer)
        XCTAssertEqual(notifier.removed, [offerID])
    }

    // MARK: 받기: 데이터 채널

    /// 들어온 데이터 채널에 첫 줄(전송 ID)과 바이트를 보낸다.
    private func deliver(_ data: Data, transferID: String? = nil, deviceID: String? = nil, on id: PeerConnectionID = 8) {
        core.peers.handle(.connected(id, route: nil, isOutbound: false))
        core.peers.handle(.received(id, PeerCodec.encode(
            .dataChannel(deviceID: deviceID ?? peerID, transferID: transferID ?? offerID)) + data))
    }

    func testAcceptedDataIsVerifiedAndSaved() {
        receiveOffer(name: "../.숨김/사진.png")
        transfer.accept(transferID: offerID)
        deliver(content)
        XCTAssertEqual(store.saved.map(\.name), ["숨김사진.png"])
        XCTAssertEqual(store.saved.first?.data, content)
        XCTAssertEqual(transfer.status, .received(fileName: "숨김사진.png"))
        XCTAssertEqual(transport.closed, [8], "받기를 마치면 받는 쪽이 데이터 채널을 닫는다")
        XCTAssertEqual(core.peers.peers.map(\.deviceID), [peerID], "데이터 채널은 피어로 등록하지 않는다")
    }

    func testDataSplitByteByByteIsReassembled() {
        receiveOffer()
        transfer.accept(transferID: offerID)
        core.peers.handle(.connected(8, route: nil, isOutbound: false))
        let line = PeerCodec.encode(.dataChannel(deviceID: peerID, transferID: offerID)) + content
        for byte in line { core.peers.handle(.received(8, Data([byte]))) }
        XCTAssertEqual(store.saved.first?.data, content)
        XCTAssertEqual(core.peers.ignoredMessageCount, 0)
    }

    func testCollidingNameGetsNumber() {
        store.existing = ["사진.png"]
        receiveOffer()
        transfer.accept(transferID: offerID)
        deliver(content)
        XCTAssertEqual(store.saved.map(\.name), ["사진 2.png"])
    }

    func testHashMismatchIsNotSaved() {
        receiveOffer(hash: sha(Data("다른 내용".utf8)))
        transfer.accept(transferID: offerID)
        deliver(content)
        XCTAssertEqual(store.saved.count, 0)
        XCTAssertEqual(transfer.status, .receiveFailed(fileName: "사진.png", reason: .checksumMismatch))
        XCTAssertEqual(transport.closed, [8])
    }

    func testSaveFailureIsShown() {
        store.fails = true
        receiveOffer()
        transfer.accept(transferID: offerID)
        deliver(content)
        XCTAssertEqual(transfer.status, .receiveFailed(fileName: "사진.png", reason: .saveFailed))
    }

    func testDataChannelForUnacceptedTransferIsClosed() {
        receiveOffer()   // 아직 수락하지 않음
        deliver(content)
        XCTAssertEqual(transport.closed, [8])
        XCTAssertEqual(store.saved.count, 0)
    }

    func testDataChannelWithUnknownIDIsClosed() {
        receiveOffer()
        transfer.accept(transferID: offerID)
        deliver(content, transferID: "guess")
        XCTAssertEqual(transport.closed, [8])
        // 원래 전송은 그대로 받을 수 있다.
        deliver(content, on: 9)
        XCTAssertEqual(store.saved.count, 1)
    }

    func testDataChannelFromOtherDeviceIsClosed() {
        receiveOffer()
        transfer.accept(transferID: offerID)
        deliver(content, deviceID: "zzz")
        XCTAssertEqual(transport.closed, [8])
    }

    func testSecondDataChannelForSameTransferIsClosed() {
        receiveOffer()
        transfer.accept(transferID: offerID)
        deliver(content.prefix(10))
        deliver(content, on: 9)
        XCTAssertEqual(transport.closed, [9])
    }

    func testBytesBeyondDeclaredSizeFail() {
        receiveOffer()
        transfer.accept(transferID: offerID)
        deliver(content + Data([0x01]))
        XCTAssertEqual(store.saved.count, 0)
        XCTAssertEqual(transfer.status, .receiveFailed(fileName: "사진.png", reason: .checksumMismatch))
    }

    func testDataChannelClosedEarlyFails() {
        receiveOffer()
        transfer.accept(transferID: offerID)
        deliver(content.prefix(10))
        core.peers.handle(.disconnected(8))
        XCTAssertEqual(store.saved.count, 0)
        XCTAssertEqual(transfer.status, .receiveFailed(fileName: "사진.png", reason: .interrupted))
    }

    func testDataChannelThatNeverArrivesTimesOut() {
        receiveOffer()
        transfer.accept(transferID: offerID)
        clock.advance(by: transfer.answerTimeout + 1)
        transfer.tick()
        XCTAssertEqual(transfer.status, .receiveFailed(fileName: "사진.png", reason: .interrupted))
        deliver(content)
        XCTAssertEqual(transport.closed, [8])
    }

    func testPeerConnectionsStillWorkWhileReceiving() {
        receiveOffer()
        transfer.accept(transferID: offerID)
        deliver(content.prefix(10))
        transport.clearSent()
        receive(.session(deviceID: peerID, active: true))
        XCTAssertTrue(core.inputSync.isPeerSessionActive)
    }

    // MARK: 이름 정리

    func testSanitizeRemovesSeparatorsAndLeadingDots() {
        XCTAssertEqual(FileNames.sanitize("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(FileNames.sanitize(".bashrc"), "bashrc")
        XCTAssertEqual(FileNames.sanitize("a:b/c.txt"), "abc.txt")
        XCTAssertEqual(FileNames.sanitize("줄\n바꿈\u{0}.txt"), "줄바꿈.txt")
        XCTAssertEqual(FileNames.sanitize("..."), FileNames.fallback)
        XCTAssertEqual(FileNames.sanitize(""), FileNames.fallback)
        XCTAssertEqual(FileNames.sanitize("보고서.pdf"), "보고서.pdf")
    }

    func testSanitizeTruncatesKeepingExtension() {
        let long = String(repeating: "가", count: 300) + ".pdf"
        let name = FileNames.sanitize(long)
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertTrue(name.hasSuffix(".pdf"))
    }

    func testCandidatesNumberBeforeExtension() {
        XCTAssertEqual(Array(FileNames.candidates(for: "a.txt").prefix(3)), ["a.txt", "a 2.txt", "a 3.txt"])
        XCTAssertEqual(Array(FileNames.candidates(for: "README").prefix(2)), ["README", "README 2"])
        XCTAssertEqual(Array(FileNames.candidates(for: "a.tar.gz").prefix(2)), ["a.tar.gz", "a.tar 2.gz"])
    }

    func testReceiveDisabledByDefault() {
        XCTAssertFalse(InMemoryFileTransferSettings().fileReceiveEnabled)
    }
}
