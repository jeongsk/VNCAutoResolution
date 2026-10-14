import CryptoKit
import XCTest
@testable import VNCAutoResolutionCore

/// 파일 전송 규칙 (가짜 포트 + FakeClock). 피어 연결은 1번, 우리가 연 데이터 채널은 7번, 들어온 데이터 채널은 8번.
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
    /// 보내는 파일: 조각(256KB) 6개 분량. 줄바꿈과 hello처럼 보이는 줄이 섞여 있다.
    private let content = Data("파일 내용\n{\"type\":\"hello\"}\n".utf8)
        + Data((0..<(5 * 256 * 1024 + 100)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    /// 받는 파일(작게).
    private let small = Data("받는 내용\n{\"type\":\"hello\"}\n".utf8) + Data(repeating: 0x0A, count: 300)
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

    private func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// 연결 `id`로 보낸 메시지(hello 제외).
    private func sent(to id: PeerConnectionID = 1) -> [PeerMessage] {
        transport.messages(to: id).filter { if case .hello = $0 { return false } else { return true } }
    }

    private func receive(_ message: PeerMessage, on id: PeerConnectionID = 1) {
        core.peers.handle(.received(id, PeerCodec.encode(message)))
    }

    private func percent(_ status: FileTransferController.Status) -> Int? {
        switch status {
        case .sending(_, let progress), .receiving(_, let progress): return progress.percent
        default: return nil
        }
    }

    // MARK: 보내기: 제안

    /// 보낸 제안의 전송 ID.
    private func sendFile() -> String? {
        transfer.send(fileAt: fileURL, to: peerID)
        guard case .fileOffer(_, let id, _, _)? = sent().last else { return nil }
        return id
    }

    func testSendOffersNameAndSizeWithoutReadingFile() throws {
        let id = try XCTUnwrap(sendFile())
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(sent(), [.fileOffer(deviceID: me, transferID: id, name: "보고서.pdf", size: content.count)])
        XCTAssertEqual(reader.opened.first?.reads, [], "제안 단계에서는 파일을 읽지 않는다")
        XCTAssertEqual(transfer.sendStatus, .waitingForAnswer(fileName: "보고서.pdf", peerName: "상대 맥"))
    }

    func testTransferIDsAreRandom() throws {
        let first = try XCTUnwrap(sendFile())
        let second = try XCTUnwrap(sendFile())
        XCTAssertNotEqual(first, second)
    }

    func testDeclinedOfferShowsReasonAndClosesFile() throws {
        let id = try XCTUnwrap(sendFile())
        receive(.fileAnswer(deviceID: peerID, transferID: id, accepted: false, reason: .noSpace, port: nil))
        XCTAssertEqual(transfer.sendStatus, .declined(fileName: "보고서.pdf", reason: .noSpace))
        XCTAssertEqual(transport.dataChannelRequests.count, 0)
        XCTAssertEqual(reader.opened.first?.isClosed, true)
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
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "보고서.pdf", reason: .peerNeedsUpdate))
    }

    func testUnreadableFileFails() {
        transfer.send(fileAt: URL(fileURLWithPath: "/tmp/없음.txt"), to: peerID)
        XCTAssertEqual(sent(), [])
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "없음.txt", reason: .readFailed))
    }

    func testNoAnswerTimesOutOnSender() throws {
        _ = try XCTUnwrap(sendFile())
        clock.advance(by: transfer.answerTimeout + 1)
        transfer.tick()
        XCTAssertEqual(transfer.sendStatus, .waitingForAnswer(fileName: "보고서.pdf", peerName: "상대 맥"),
                       "받는 쪽의 시간 초과 거절을 먼저 기다린다")
        clock.advance(by: 30)
        transfer.tick()
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "보고서.pdf", reason: .noAnswer))
    }

    func testPeerDisconnectWhileWaitingFails() throws {
        _ = try XCTUnwrap(sendFile())
        core.peers.handle(.disconnected(1))
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "보고서.pdf", reason: .connectionFailed))
    }

    func testCancelWhileWaitingForAnswerTellsPeer() throws {
        let id = try XCTUnwrap(sendFile())
        transfer.cancelSend()
        XCTAssertEqual(sent().last, .fileEnd(deviceID: me, transferID: id, result: .canceled))
        XCTAssertEqual(transfer.sendStatus, .canceled(fileName: "보고서.pdf", byPeer: false))
        XCTAssertFalse(transfer.isSending)
        // 늦게 온 수락은 무시한다.
        receive(.fileAnswer(deviceID: peerID, transferID: id, accepted: true, reason: nil, port: 5000))
        XCTAssertEqual(transport.dataChannelRequests.count, 0)
    }

    func testSendingAnotherFileCancelsPrevious() throws {
        let first = try XCTUnwrap(sendFile())
        let second = try XCTUnwrap(sendFile())
        XCTAssertTrue(sent().contains(.fileEnd(deviceID: me, transferID: first, result: .canceled)))
        XCTAssertEqual(reader.opened.first?.isClosed, true)
        XCTAssertNotEqual(first, second)
    }

    // MARK: 보내기: 스트리밍

    /// 제안 → 수락 → 데이터 채널(7번) 열림까지.
    private func startStreaming() throws -> String {
        let id = try XCTUnwrap(sendFile())
        receive(.fileAnswer(deviceID: peerID, transferID: id, accepted: true, reason: nil, port: 5000))
        core.peers.handle(.dataChannelOpened(7, transferID: id))
        return id
    }

    /// 데이터 채널(7번)로 보낸 머리말과 그 뒤 바이트.
    private func channelStream() -> (PeerMessage?, Data) {
        let bytes = transport.bytes(to: 7)
        guard let newline = bytes.firstIndex(of: 0x0A) else { return (nil, bytes) }
        return (PeerCodec.decode(bytes[..<newline]), Data(bytes[bytes.index(after: newline)...]))
    }

    /// 데이터 채널로 보낸 것(머리말 제외) 조각 수.
    private var chunksSent: Int { transport.sent.filter { $0.id == 7 }.count - 1 }

    /// 전송 계층이 넘겼다고 알린다. 보낼 게 없을 때까지 반복하고, 그동안 넘기지 않은 조각이 창을 넘지 않는지 본다.
    private func drainAll(file: StaticString = #filePath, line: UInt = #line) {
        var drained = 0
        while drained < chunksSent {
            XCTAssertLessThanOrEqual(chunksSent - drained, transfer.sendWindow, "창보다 많이 보냄", file: file, line: line)
            core.peers.handle(.dataSent(7))
            drained += 1
        }
    }

    func testAcceptedOfferOpensDataChannel() throws {
        let id = try XCTUnwrap(sendFile())
        receive(.fileAnswer(deviceID: peerID, transferID: id, accepted: true, reason: nil, port: 5000))
        XCTAssertEqual(transport.dataChannelRequests.map(\.peer), [1])
        XCTAssertEqual(transport.dataChannelRequests.map(\.port), [5000])
        XCTAssertEqual(transport.dataChannelRequests.map(\.transferID), [id])
        XCTAssertEqual(transfer.sendStatus,
                       .sending(fileName: "보고서.pdf", progress: .init(done: 0, total: content.count)))
    }

    func testStreamsOnlyWindowOfChunksUntilTransportDrains() throws {
        _ = try startStreaming()
        XCTAssertEqual(chunksSent, transfer.sendWindow, "넘겼다는 알림 전에는 창만큼만 보낸다")
        XCTAssertEqual(reader.opened.first?.reads, Array(repeating: transfer.chunkSize, count: transfer.sendWindow))
        core.peers.handle(.dataSent(7))
        XCTAssertEqual(chunksSent, transfer.sendWindow + 1)
        XCTAssertEqual(core.peers.peers.map(\.deviceID), [peerID], "데이터 채널은 피어 목록에 없다")
    }

    func testStreamSendsHeaderFileBytesThenDigest() throws {
        let id = try startStreaming()
        drainAll()
        let (header, body) = channelStream()
        XCTAssertEqual(header, .dataChannel(deviceID: me, transferID: id))
        XCTAssertTrue(body == content + digest(content), "파일 바이트 뒤에 SHA-256")
        XCTAssertTrue(reader.opened.first!.reads.allSatisfy { $0 <= transfer.chunkSize })
    }

    func testProgressCountsDrainedBytes() throws {
        _ = try startStreaming()
        core.peers.handle(.dataSent(7))
        XCTAssertEqual(transfer.sendStatus,
                       .sending(fileName: "보고서.pdf", progress: .init(done: transfer.chunkSize, total: content.count)))
    }

    func testAllSentWaitsForReceiverConfirmation() throws {
        let id = try startStreaming()
        drainAll()
        XCTAssertEqual(percent(transfer.sendStatus), 100)
        core.peers.handle(.disconnected(7))   // 받는 쪽이 다 받고 닫음
        XCTAssertEqual(percent(transfer.sendStatus), 100, "받는 쪽 결과가 올 때까지 \"보냄\"이 아니다")
        receive(.fileEnd(deviceID: peerID, transferID: id, result: .saved))
        XCTAssertEqual(transfer.sendStatus, .sent(fileName: "보고서.pdf"))
        XCTAssertEqual(reader.opened.first?.isClosed, true)
        XCTAssertFalse(transfer.isSending)
    }

    func testReceiverFailuresAreShownOnSender() throws {
        let cases: [(FileEndResult, FileTransferController.Status)] = [
            (.checksumMismatch, .sendFailed(fileName: "보고서.pdf", reason: .peerVerificationFailed)),
            (.saveFailed, .sendFailed(fileName: "보고서.pdf", reason: .peerSaveFailed)),
            (.interrupted, .sendFailed(fileName: "보고서.pdf", reason: .interrupted)),
            (.canceled, .canceled(fileName: "보고서.pdf", byPeer: true)),
        ]
        for (result, expected) in cases {
            let id = try startStreaming()
            receive(.fileEnd(deviceID: peerID, transferID: id, result: result))
            XCTAssertEqual(transfer.sendStatus, expected, "\(result)")
            XCTAssertTrue(transport.closed.contains(7))
        }
    }

    func testEndFromAnotherPeerIsIgnored() throws {
        connectPeer(id: 2, deviceID: "bbb")
        let id = try startStreaming()
        receive(.fileEnd(deviceID: "bbb", transferID: id, result: .canceled), on: 2)
        XCTAssertTrue(transfer.isSending)
    }

    func testNoConfirmationTimesOut() throws {
        _ = try startStreaming()
        drainAll()
        clock.advance(by: transfer.answerTimeout + 1)
        transfer.tick()
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "보고서.pdf", reason: .noConfirmation))
    }

    func testLateConfirmationReplacesGuess() throws {
        let id = try startStreaming()
        drainAll()
        clock.advance(by: transfer.answerTimeout + 1)
        transfer.tick()
        receive(.fileEnd(deviceID: peerID, transferID: id, result: .saved))
        XCTAssertEqual(transfer.sendStatus, .sent(fileName: "보고서.pdf"))
    }

    func testStalledSendTimesOutAndTellsPeer() throws {
        let id = try startStreaming()
        clock.advance(by: transfer.answerTimeout + 1)
        transfer.tick()
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "보고서.pdf", reason: .interrupted))
        XCTAssertEqual(sent().last, .fileEnd(deviceID: me, transferID: id, result: .interrupted))
        XCTAssertTrue(transport.closed.contains(7))
    }

    func testDrainKeepsSendAlive() throws {
        _ = try startStreaming()
        clock.advance(by: transfer.answerTimeout - 1)
        core.peers.handle(.dataSent(7))
        clock.advance(by: 2)
        transfer.tick()
        XCTAssertTrue(transfer.isSending)
    }

    func testCancelDuringSendStopsAndTellsPeer() throws {
        let id = try startStreaming()
        transfer.cancelSend()
        XCTAssertEqual(sent().last, .fileEnd(deviceID: me, transferID: id, result: .canceled))
        XCTAssertTrue(transport.closed.contains(7))
        XCTAssertEqual(transfer.sendStatus, .canceled(fileName: "보고서.pdf", byPeer: false))
        XCTAssertEqual(reader.opened.first?.isClosed, true)
        let before = transport.sent.count
        core.peers.handle(.dataSent(7))
        XCTAssertEqual(transport.sent.count, before, "취소한 뒤에는 더 보내지 않는다")
    }

    func testReceiverClosingChannelStopsSendingAndWaitsForReason() throws {
        let id = try startStreaming()
        core.peers.handle(.disconnected(7))
        XCTAssertTrue(transfer.isSending)
        // 받는 쪽의 취소 알림이 채널이 닫힌 뒤에 와도 취소로 보인다.
        receive(.fileEnd(deviceID: peerID, transferID: id, result: .canceled))
        XCTAssertEqual(transfer.sendStatus, .canceled(fileName: "보고서.pdf", byPeer: true))
    }

    func testCancelArrivingAfterStallGuessReplacesIt() throws {
        let id = try startStreaming()
        core.peers.handle(.disconnected(7))
        clock.advance(by: transfer.answerTimeout + 1)
        transfer.tick()
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "보고서.pdf", reason: .interrupted))
        receive(.fileEnd(deviceID: peerID, transferID: id, result: .canceled))
        XCTAssertEqual(transfer.sendStatus, .canceled(fileName: "보고서.pdf", byPeer: true))
    }

    func testReadFailureMidStreamTellsPeer() throws {
        let id = try XCTUnwrap(sendFile())
        reader.opened.first?.failsAt = transfer.chunkSize
        receive(.fileAnswer(deviceID: peerID, transferID: id, accepted: true, reason: nil, port: 5000))
        core.peers.handle(.dataChannelOpened(7, transferID: id))
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "보고서.pdf", reason: .readFailed))
        XCTAssertEqual(sent().last, .fileEnd(deviceID: me, transferID: id, result: .interrupted))
        XCTAssertTrue(transport.closed.contains(7))
    }

    func testPeerDisconnectWhileSendingFails() throws {
        _ = try startStreaming()
        core.peers.handle(.disconnected(1))
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "보고서.pdf", reason: .connectionFailed))
        XCTAssertTrue(transport.closed.contains(7))
    }

    func testDataChannelOpenFailureTellsPeer() throws {
        let id = try XCTUnwrap(sendFile())
        receive(.fileAnswer(deviceID: peerID, transferID: id, accepted: true, reason: nil, port: 5000))
        core.peers.handle(.dataChannelFailed(transferID: id))
        XCTAssertEqual(transfer.sendStatus, .sendFailed(fileName: "보고서.pdf", reason: .connectionFailed))
        XCTAssertEqual(sent().last, .fileEnd(deviceID: me, transferID: id, result: .interrupted))
    }

    func testEmptyFileSendsOnlyDigest() throws {
        reader.files[fileURL.path] = Data()
        let id = try startStreaming()
        drainAll()
        let (header, body) = channelStream()
        XCTAssertEqual(header, .dataChannel(deviceID: me, transferID: id))
        XCTAssertEqual(body, digest(Data()))
    }

    // MARK: 받기: 제안·수락·거절·시간 초과

    private let offerID = "t-123"

    private func receiveOffer(name: String = "사진.png", size: Int? = nil) {
        receive(.fileOffer(deviceID: peerID, transferID: offerID, name: name, size: size ?? small.count))
    }

    func testOfferIsShownInNotificationAndMenu() {
        receiveOffer()
        let offer = IncomingFileOffer(transferID: offerID, deviceID: peerID, peerName: "상대 맥",
                                      fileName: "사진.png", size: small.count)
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
        XCTAssertEqual(transfer.receiveStatus,
                       .receiving(fileName: "사진.png", progress: .init(done: 0, total: small.count)))
        XCTAssertTrue(store.files.isEmpty, "임시 파일은 데이터 채널이 열릴 때 만든다")
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
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .timedOut))
    }

    func testReceiveDisabledDeclinesWithoutAsking() {
        settings.fileReceiveEnabled = false
        receiveOffer()
        XCTAssertEqual(sent(), [.fileAnswer(deviceID: me, transferID: offerID, accepted: false, reason: .disabled, port: nil)])
        XCTAssertEqual(notifier.shown, [])
    }

    func testLargeOfferIsShownWhenThereIsSpace() {
        store.free = 100 * 1024 * 1024 * 1024
        receiveOffer(size: 50 * 1024 * 1024 * 1024)
        XCTAssertEqual(transfer.incomingOffer?.size, 50 * 1024 * 1024 * 1024)
    }

    func testOfferLargerThanFreeSpaceIsDeclined() {
        store.free = 1000
        receiveOffer(size: 1001)
        XCTAssertEqual(sent(), [.fileAnswer(deviceID: me, transferID: offerID, accepted: false, reason: .noSpace, port: nil)])
        XCTAssertEqual(notifier.shown, [])
    }

    func testNegativeSizeIsDeclined() {
        receiveOffer(size: -1)
        XCTAssertEqual(notifier.shown, [])
    }

    func testSecondOfferWhilePendingIsBusy() {
        receiveOffer()
        receive(.fileOffer(deviceID: peerID, transferID: "t-2", name: "b", size: 1))
        XCTAssertEqual(sent(), [.fileAnswer(deviceID: me, transferID: "t-2", accepted: false, reason: .busy, port: nil)])
        XCTAssertEqual(transfer.incomingOffer?.transferID, offerID)
    }

    func testPeerDisconnectClearsPendingOffer() {
        receiveOffer()
        core.peers.handle(.disconnected(1))
        XCTAssertNil(transfer.incomingOffer)
        XCTAssertEqual(notifier.removed, [offerID])
    }

    func testSenderCancelWhilePendingRemovesOffer() {
        receiveOffer()
        receive(.fileEnd(deviceID: peerID, transferID: offerID, result: .canceled))
        XCTAssertNil(transfer.incomingOffer)
        XCTAssertEqual(notifier.removed, [offerID])
        XCTAssertEqual(transfer.receiveStatus, .canceled(fileName: "사진.png", byPeer: true))
    }

    // MARK: 받기: 데이터 채널

    /// 들어온 데이터 채널에 첫 줄(전송 ID)과 바이트를 보낸다.
    private func deliver(_ data: Data, transferID: String? = nil, deviceID: String? = nil, on id: PeerConnectionID = 8) {
        core.peers.handle(.connected(id, route: nil, isOutbound: false))
        core.peers.handle(.received(id, PeerCodec.encode(
            .dataChannel(deviceID: deviceID ?? peerID, transferID: transferID ?? offerID)) + data))
    }

    /// 받는 파일 바이트 + SHA-256.
    private var stream: Data { small + digest(small) }

    private func acceptOffer(name: String = "사진.png", size: Int? = nil) {
        receiveOffer(name: name, size: size)
        transfer.accept(transferID: offerID)
        transport.clearSent()
    }

    func testDataIsWrittenToTempFileVerifiedAndSaved() {
        acceptOffer(name: "../.숨김/사진.png")
        deliver(stream)
        XCTAssertEqual(store.files.count, 1)
        XCTAssertEqual(store.files.first?.isCommitted, true)
        XCTAssertEqual(store.files.first?.isDiscarded, false)
        XCTAssertEqual(store.saved.map(\.name), ["숨김사진.png"])
        XCTAssertEqual(store.saved.first?.data, small)
        XCTAssertEqual(transfer.receiveStatus, .received(fileName: "숨김사진.png"))
        XCTAssertEqual(sent(), [.fileEnd(deviceID: me, transferID: offerID, result: .saved)])
        XCTAssertEqual(transport.closed, [8], "받기를 마치면 받는 쪽이 데이터 채널을 닫는다")
        XCTAssertEqual(core.peers.peers.map(\.deviceID), [peerID], "데이터 채널은 피어로 등록하지 않는다")
        XCTAssertFalse(transfer.isReceiving)
    }

    func testDataSplitByteByByteIsReassembled() {
        acceptOffer()
        core.peers.handle(.connected(8, route: nil, isOutbound: false))
        let line = PeerCodec.encode(.dataChannel(deviceID: peerID, transferID: offerID)) + stream
        for byte in line { core.peers.handle(.received(8, Data([byte]))) }
        XCTAssertEqual(store.saved.first?.data, small)
        XCTAssertEqual(core.peers.ignoredMessageCount, 0)
    }

    func testReceiveProgressNotifiesOnlyWhenPercentChanges() {
        let payload = Data(repeating: 0x41, count: 1000)
        acceptOffer(size: payload.count)
        var changes = 0
        transfer.onChange = { changes += 1 }
        core.peers.handle(.connected(8, route: nil, isOutbound: false))
        core.peers.handle(.received(8, PeerCodec.encode(.dataChannel(deviceID: peerID, transferID: offerID))))
        for (i, byte) in payload.enumerated() {
            core.peers.handle(.received(8, Data([byte])))
            if i == 499 {
                XCTAssertEqual(transfer.receiveStatus,
                               .receiving(fileName: "사진.png", progress: .init(done: 500, total: 1000)))
            }
        }
        XCTAssertEqual(changes, 100, "1000바이트를 1바이트씩 받아도 퍼센트가 바뀔 때만 알린다")
    }

    func testCollidingNameGetsNumber() {
        store.existing = ["사진.png"]
        acceptOffer()
        deliver(stream)
        XCTAssertEqual(store.saved.map(\.name), ["사진 2.png"])
    }

    func testDigestMismatchDiscardsTempFile() {
        acceptOffer()
        deliver(small + digest(Data("다른 내용".utf8)))
        XCTAssertEqual(store.saved.count, 0)
        XCTAssertEqual(store.files.first?.isDiscarded, true)
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .checksumMismatch))
        XCTAssertEqual(sent(), [.fileEnd(deviceID: me, transferID: offerID, result: .checksumMismatch)])
        XCTAssertEqual(transport.closed, [8])
    }

    func testBytesBeyondDigestFail() {
        acceptOffer()
        deliver(stream + Data([0x01]))
        XCTAssertEqual(store.saved.count, 0)
        XCTAssertEqual(store.files.first?.isDiscarded, true)
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .checksumMismatch))
    }

    func testTempFileFailureRefusesChannel() {
        store.beginFails = true
        acceptOffer()
        deliver(stream)
        XCTAssertEqual(transport.closed, [8])
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .saveFailed))
        XCTAssertEqual(sent(), [.fileEnd(deviceID: me, transferID: offerID, result: .saveFailed)])
    }

    func testWriteFailureDiscardsTempFile() {
        store.writeFails = true
        acceptOffer()
        deliver(stream)
        XCTAssertEqual(store.files.first?.isDiscarded, true)
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .saveFailed))
        XCTAssertEqual(sent(), [.fileEnd(deviceID: me, transferID: offerID, result: .saveFailed)])
        XCTAssertEqual(transport.closed, [8])
    }

    func testCommitFailureDiscardsTempFile() {
        store.commitFails = true
        acceptOffer()
        deliver(stream)
        XCTAssertEqual(store.files.first?.isDiscarded, true)
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .saveFailed))
    }

    func testDataChannelForUnacceptedTransferIsClosed() {
        receiveOffer()   // 아직 수락하지 않음
        deliver(stream)
        XCTAssertEqual(transport.closed, [8])
        XCTAssertTrue(store.files.isEmpty)
    }

    func testDataChannelWithUnknownIDIsClosed() {
        acceptOffer()
        deliver(stream, transferID: "guess")
        XCTAssertEqual(transport.closed, [8])
        // 원래 전송은 그대로 받을 수 있다.
        deliver(stream, on: 9)
        XCTAssertEqual(store.saved.count, 1)
    }

    func testDataChannelFromOtherDeviceIsClosed() {
        acceptOffer()
        deliver(stream, deviceID: "zzz")
        XCTAssertEqual(transport.closed, [8])
    }

    func testSecondDataChannelForSameTransferIsClosed() {
        acceptOffer()
        deliver(stream.prefix(10))
        deliver(stream, on: 9)
        XCTAssertEqual(transport.closed, [9])
        XCTAssertEqual(store.files.count, 1)
    }

    func testDataChannelClosedEarlyDiscardsAndTellsSender() {
        acceptOffer()
        deliver(stream.prefix(10))
        core.peers.handle(.disconnected(8))
        XCTAssertEqual(store.saved.count, 0)
        XCTAssertEqual(store.files.first?.isDiscarded, true)
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .interrupted))
        XCTAssertEqual(sent(), [.fileEnd(deviceID: me, transferID: offerID, result: .interrupted)])
    }

    func testDataChannelThatNeverArrivesTimesOut() {
        acceptOffer()
        clock.advance(by: transfer.answerTimeout + 1)
        transfer.tick()
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .interrupted))
        deliver(stream)
        XCTAssertEqual(transport.closed, [8])
    }

    func testStalledDataChannelTimesOutAndFreesReceiver() {
        acceptOffer()
        deliver(stream.prefix(10))
        clock.advance(by: transfer.answerTimeout + 1)
        transfer.tick()
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .interrupted))
        XCTAssertEqual(store.files.first?.isDiscarded, true)
        XCTAssertEqual(transport.closed, [8])
        // 다음 제안을 받을 수 있다.
        receive(.fileOffer(deviceID: peerID, transferID: "t-2", name: "b", size: 1))
        XCTAssertEqual(transfer.incomingOffer?.transferID, "t-2")
    }

    func testDataKeepsStalledTimerAlive() {
        acceptOffer()
        deliver(stream.prefix(10))
        clock.advance(by: transfer.answerTimeout - 1)
        core.peers.handle(.received(8, stream.dropFirst(10).prefix(10)))
        clock.advance(by: 2)
        transfer.tick()
        XCTAssertTrue(transfer.isReceiving)
    }

    func testCancelReceiveDiscardsAndTellsSender() {
        acceptOffer()
        deliver(stream.prefix(10))
        transfer.cancelReceive()
        XCTAssertEqual(store.files.first?.isDiscarded, true)
        XCTAssertEqual(transport.closed, [8])
        XCTAssertEqual(sent(), [.fileEnd(deviceID: me, transferID: offerID, result: .canceled)])
        XCTAssertEqual(transfer.receiveStatus, .canceled(fileName: "사진.png", byPeer: false))
        // 이미 보내 둔 바이트가 더 와도 쓰지 않는다.
        core.peers.handle(.received(8, stream.dropFirst(10)))
        XCTAssertEqual(store.saved.count, 0)
    }

    func testSenderCancelDuringReceiveDiscards() {
        acceptOffer()
        deliver(stream.prefix(10))
        receive(.fileEnd(deviceID: peerID, transferID: offerID, result: .canceled))
        XCTAssertEqual(store.files.first?.isDiscarded, true)
        XCTAssertEqual(transport.closed, [8])
        XCTAssertEqual(transfer.receiveStatus, .canceled(fileName: "사진.png", byPeer: true))
        XCTAssertEqual(sent(), [], "상대가 끝낸 전송에는 결과를 다시 보내지 않는다")
    }

    func testSenderCancelArrivingAfterChannelCloseShowsCanceled() {
        acceptOffer()
        deliver(stream.prefix(10))
        core.peers.handle(.disconnected(8))
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .interrupted))
        receive(.fileEnd(deviceID: peerID, transferID: offerID, result: .canceled))
        XCTAssertEqual(transfer.receiveStatus, .canceled(fileName: "사진.png", byPeer: true))
    }

    func testSenderCancelAfterSaveKeepsReceived() {
        acceptOffer()
        deliver(stream)
        receive(.fileEnd(deviceID: peerID, transferID: offerID, result: .canceled))
        XCTAssertEqual(transfer.receiveStatus, .received(fileName: "사진.png"))
    }

    func testPeerDisconnectDuringReceiveDiscards() {
        acceptOffer()
        deliver(stream.prefix(10))
        core.peers.handle(.disconnected(1))
        XCTAssertEqual(store.files.first?.isDiscarded, true)
        XCTAssertEqual(transfer.receiveStatus, .receiveFailed(fileName: "사진.png", reason: .interrupted))
    }

    func testPeerConnectionsStillWorkWhileReceiving() {
        acceptOffer()
        deliver(stream.prefix(10))
        receive(.session(deviceID: peerID, active: true))
        XCTAssertTrue(core.inputSync.isPeerSessionActive)
    }

    func testSendAndReceiveAtTheSameTimeKeepSeparateStatus() throws {
        acceptOffer()
        deliver(stream.prefix(10))
        _ = try startStreaming()
        XCTAssertEqual(transfer.receiveStatus,
                       .receiving(fileName: "사진.png", progress: .init(done: 10, total: small.count)))
        XCTAssertEqual(percent(transfer.sendStatus), 0)
        core.peers.handle(.received(8, stream.dropFirst(10)))
        XCTAssertEqual(transfer.receiveStatus, .received(fileName: "사진.png"))
        XCTAssertTrue(transfer.isSending)
    }

    // MARK: 이름 정리

    func testSanitizeRemovesSeparatorsAndLeadingDots() {
        XCTAssertEqual(FileNames.sanitize("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(FileNames.sanitize(".bashrc"), "bashrc")
        XCTAssertEqual(FileNames.sanitize("a:b/c.txt"), "abc.txt")
        XCTAssertEqual(FileNames.sanitize("줄\n바꿈\u{0}.txt"), "줄바꿈.txt")
        XCTAssertEqual(FileNames.sanitize(". .x"), "x")
        XCTAssertEqual(FileNames.sanitize(" . . "), FileNames.fallback)
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
