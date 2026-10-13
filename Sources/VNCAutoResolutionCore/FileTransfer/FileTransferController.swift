import CryptoKit
import Foundation
import os

/// 파일 하나를 상대 Mac으로 보내고 받는다.
///
/// 제안(`fileOffer`)과 답(`fileAnswer`)은 제어 연결로 주고받고, 파일 바이트는 전송마다 새로 여는 데이터 채널로 보낸다.
/// 큰 파일이 한/영 동기화나 세션 신호를 막지 않게 하기 위해서다. 받는 쪽은 매번 수락해야 한다.
/// 원격 세션 여부와 무관하게 피어가 연결돼 있으면 보낼 수 있다.
///
/// 이번 단계는 파일을 메모리에 통째로 올린다(상한 20MB). 스트리밍은 #19.
///
/// 스레드: 메인 스레드 전용 (PeerManager와 같다).
public final class FileTransferController: PeerDataChannelHandling {
    /// 보내고 받을 수 있는 파일 크기 상한(바이트).
    public static let maxFileBytes = 20 * 1024 * 1024

    public enum SendFailure: Equatable {
        case peerNeedsUpdate    // 상대가 파일 전송 기능을 알리지 않음
        case tooLarge
        case readFailed
        case noPeer
        case noAnswer           // 받는 쪽에서 답이 오지 않음
        case connectionFailed   // 피어 연결이 끊기거나 데이터 채널을 열지 못함
    }

    public enum ReceiveFailure: Equatable {
        case timedOut           // 60초 안에 응답하지 않아 거절함
        case checksumMismatch   // 크기나 SHA-256이 맞지 않음
        case saveFailed
        case interrupted        // 다 받기 전에 데이터 채널이 끊기거나 오지 않음
    }

    /// 마지막 전송 상태. 메뉴 표시용. 보내기와 받기가 같은 자리를 쓴다.
    public enum Status: Equatable {
        case none
        case waitingForAnswer(fileName: String, peerName: String)
        case sending(fileName: String)
        case sent(fileName: String)
        case declined(fileName: String, reason: FileDeclineReason)
        case sendFailed(fileName: String, reason: SendFailure)
        case receiving(fileName: String)
        /// `fileName`은 실제로 저장한 이름.
        case received(fileName: String)
        case receiveFailed(fileName: String, reason: ReceiveFailure)
    }

    static let log = Logger(subsystem: "com.jeongsk.VNCAutoResolution", category: "filetransfer")

    /// 받는 쪽이 제안에 답해야 하는 시간(초). 넘기면 거절한다.
    public let answerTimeout: TimeInterval
    /// 보내는 쪽이 답을 기다리는 시간(초). 받는 쪽의 시간 초과 거절이 먼저 오도록 여유를 둔다.
    public let senderWaitTimeout: TimeInterval

    public private(set) var status: Status = .none
    /// 사용자의 응답을 기다리는 받은 제안. 한 번에 하나만 둔다.
    public private(set) var incomingOffer: IncomingFileOffer?
    /// 상태가 바뀔 때마다 불린다.
    public var onChange: (() -> Void)?

    private struct Outgoing {
        let transferID: String
        let deviceID: String
        let fileName: String
        let data: Data
        let offeredAt: Date
        var accepted = false
        var channelOpened = false
    }

    private struct PendingOffer {
        let offer: IncomingFileOffer
        let sha256: String
        let receivedAt: Date
    }

    private struct Receiving {
        let offer: IncomingFileOffer
        let sha256: String
        let acceptedAt: Date
        var channelOpened = false
        var buffer = Data()
    }

    private let reader: LocalFileReading
    private let store: ReceivedFileStoring
    private let notifier: FileOfferNotifying
    private let settings: FileTransferSettingsStoring
    private let peers: PeerManager
    private let clock: Clock

    private var outgoing: Outgoing?
    private var pending: PendingOffer?
    private var receiving: Receiving?

    public init(
        reader: LocalFileReading,
        store: ReceivedFileStoring,
        notifier: FileOfferNotifying,
        settings: FileTransferSettingsStoring,
        peers: PeerManager,
        clock: Clock,
        answerTimeout: TimeInterval = 60,
        senderWaitTimeout: TimeInterval = 80
    ) {
        self.reader = reader
        self.store = store
        self.notifier = notifier
        self.settings = settings
        self.peers = peers
        self.clock = clock
        self.answerTimeout = answerTimeout
        self.senderWaitTimeout = senderWaitTimeout
    }

    // MARK: 상태

    public var receiveEnabled: Bool {
        get { settings.fileReceiveEnabled }
        set { settings.fileReceiveEnabled = newValue; onChange?() }
    }

    /// 이 피어가 파일 전송 기능을 알렸는지.
    public func canSend(to peer: PeerManager.Peer) -> Bool {
        peer.features.contains(PeerFeature.fileTransfer)
    }

    // MARK: 보내기

    /// 파일을 이 피어에게 보내자고 제안한다. 이전에 보내던 제안은 잊는다.
    public func send(fileAt url: URL, to deviceID: String) {
        let fileName = url.lastPathComponent
        guard let peer = peers.peers.first(where: { $0.deviceID == deviceID }) else {
            return setStatus(.sendFailed(fileName: fileName, reason: .noPeer))
        }
        guard canSend(to: peer) else { return setStatus(.sendFailed(fileName: fileName, reason: .peerNeedsUpdate)) }
        let data: Data
        do {
            guard try reader.fileSize(at: url) <= Self.maxFileBytes else {
                return setStatus(.sendFailed(fileName: fileName, reason: .tooLarge))
            }
            data = try reader.readFile(at: url)
        } catch {
            return setStatus(.sendFailed(fileName: fileName, reason: .readFailed))
        }
        guard data.count <= Self.maxFileBytes else { return setStatus(.sendFailed(fileName: fileName, reason: .tooLarge)) }

        if let old = outgoing { peers.closeDataChannel(transferID: old.transferID) }
        let transferID = UUID().uuidString
        outgoing = Outgoing(transferID: transferID, deviceID: deviceID, fileName: fileName, data: data, offeredAt: clock.now)
        Self.log.debug("offer \(transferID, privacy: .public): \(data.count, privacy: .public)바이트")
        peers.send(.fileOffer(deviceID: peers.deviceID, transferID: transferID, name: fileName,
                              size: data.count, sha256: Self.hex(SHA256.hash(data: data))),
                   toDeviceID: deviceID)
        setStatus(.waitingForAnswer(fileName: fileName, peerName: peer.name))
    }

    // MARK: 받기: 사용자 응답

    public func accept(transferID: String) {
        guard let pending, pending.offer.transferID == transferID else { return }
        self.pending = nil
        incomingOffer = nil
        notifier.removeOffer(transferID: transferID)
        receiving = Receiving(offer: pending.offer, sha256: pending.sha256, acceptedAt: clock.now)
        peers.send(.fileAnswer(deviceID: peers.deviceID, transferID: transferID, accepted: true, reason: nil,
                               port: peers.listenPort.map(Int.init)),
                   toDeviceID: pending.offer.deviceID)
        setStatus(.receiving(fileName: pending.offer.fileName))
    }

    public func decline(transferID: String) {
        guard let pending, pending.offer.transferID == transferID else { return }
        clearPending()
        answer(pending.offer.deviceID, transferID, declined: .declined)
        onChange?()
    }

    // MARK: 메시지

    /// 피어가 보낸 `fileOffer`/`fileAnswer`를 처리한다.
    public func handle(_ message: PeerMessage, from peer: PeerManager.Peer) {
        switch message {
        case .fileOffer(_, let transferID, let name, let size, let sha256):
            receiveOffer(transferID: transferID, name: name, size: size, sha256: sha256, from: peer)
        case .fileAnswer(_, let transferID, let accepted, let reason, let port):
            guard var outgoing, outgoing.transferID == transferID, outgoing.deviceID == peer.deviceID,
                  !outgoing.accepted else { return }
            guard accepted else {
                self.outgoing = nil
                return setStatus(.declined(fileName: outgoing.fileName, reason: reason ?? .declined))
            }
            outgoing.accepted = true
            self.outgoing = outgoing
            let listenPort = port.flatMap { UInt16(exactly: $0) }
            guard peers.openDataChannel(toDeviceID: peer.deviceID, port: listenPort, transferID: transferID) else {
                self.outgoing = nil
                return setStatus(.sendFailed(fileName: outgoing.fileName, reason: .connectionFailed))
            }
            setStatus(.sending(fileName: outgoing.fileName))
        default:
            break
        }
    }

    private func receiveOffer(transferID: String, name: String, size: Int, sha256: String, from peer: PeerManager.Peer) {
        guard receiveEnabled else { return answer(peer.deviceID, transferID, declined: .disabled) }
        guard size >= 0, size <= Self.maxFileBytes else { return answer(peer.deviceID, transferID, declined: .tooLarge) }
        guard pending == nil, receiving == nil else { return answer(peer.deviceID, transferID, declined: .busy) }
        let offer = IncomingFileOffer(
            transferID: transferID, deviceID: peer.deviceID, peerName: peer.name,
            fileName: FileNames.sanitize(name), size: size)
        pending = PendingOffer(offer: offer, sha256: sha256.lowercased(), receivedAt: clock.now)
        incomingOffer = offer
        notifier.showOffer(offer)
        onChange?()
    }

    private func answer(_ deviceID: String, _ transferID: String, declined reason: FileDeclineReason) {
        Self.log.debug("decline \(transferID, privacy: .public): \(reason.rawValue, privacy: .public)")
        peers.send(.fileAnswer(deviceID: peers.deviceID, transferID: transferID, accepted: false, reason: reason, port: nil),
                   toDeviceID: deviceID)
    }

    // MARK: 주기 작업·피어 변화

    /// 시간 초과 처리. 앱의 주기 작업(수 초마다)에서 부른다.
    public func tick() {
        let now = clock.now
        if let pending, now.timeIntervalSince(pending.receivedAt) >= answerTimeout {
            clearPending()
            answer(pending.offer.deviceID, pending.offer.transferID, declined: .timeout)
            setStatus(.receiveFailed(fileName: pending.offer.fileName, reason: .timedOut))
        }
        if let receiving, !receiving.channelOpened, now.timeIntervalSince(receiving.acceptedAt) >= answerTimeout {
            self.receiving = nil
            setStatus(.receiveFailed(fileName: receiving.offer.fileName, reason: .interrupted))
        }
        if let outgoing, !outgoing.accepted, now.timeIntervalSince(outgoing.offeredAt) >= senderWaitTimeout {
            self.outgoing = nil
            setStatus(.sendFailed(fileName: outgoing.fileName, reason: .noAnswer))
        }
    }

    /// 피어 목록이 바뀌었을 때 부른다. 끊긴 피어와 주고받던 제안을 정리한다. (데이터 채널은 따로 끊김을 알린다)
    public func peersChanged() {
        let connected = Set(peers.peers.map(\.deviceID))
        if let pending, !connected.contains(pending.offer.deviceID) {
            clearPending()
            onChange?()
        }
        if let outgoing, !outgoing.accepted, !connected.contains(outgoing.deviceID) {
            self.outgoing = nil
            setStatus(.sendFailed(fileName: outgoing.fileName, reason: .connectionFailed))
        }
    }

    // MARK: PeerDataChannelHandling

    public func shouldAcceptDataChannel(transferID: String, from deviceID: String) -> Bool {
        guard var receiving, receiving.offer.transferID == transferID, receiving.offer.deviceID == deviceID,
              !receiving.channelOpened else { return false }
        receiving.channelOpened = true
        self.receiving = receiving
        return true
    }

    public func dataChannelReceived(transferID: String, data: Data) {
        guard var receiving, receiving.offer.transferID == transferID else { return }
        receiving.buffer.append(data)
        self.receiving = receiving
        let size = receiving.offer.size
        if receiving.buffer.count < size { return }
        // 다 받았거나 넘쳤다. 받는 쪽이 채널을 닫는다.
        self.receiving = nil
        peers.closeDataChannel(transferID: transferID)
        let fileName = receiving.offer.fileName
        guard receiving.buffer.count == size,
              Self.hex(SHA256.hash(data: receiving.buffer)) == receiving.sha256 else {
            Self.log.error("recv \(transferID, privacy: .public): 검증 실패")
            return setStatus(.receiveFailed(fileName: fileName, reason: .checksumMismatch))
        }
        do {
            let saved = try store.save(receiving.buffer, preferredName: fileName)
            setStatus(.received(fileName: saved))
        } catch {
            Self.log.error("recv \(transferID, privacy: .public): 저장 실패 \(error.localizedDescription, privacy: .public)")
            setStatus(.receiveFailed(fileName: fileName, reason: .saveFailed))
        }
    }

    public func dataChannelOpened(transferID: String) {
        guard var outgoing, outgoing.transferID == transferID, outgoing.accepted, !outgoing.channelOpened else {
            peers.closeDataChannel(transferID: transferID)
            return
        }
        outgoing.channelOpened = true
        self.outgoing = outgoing
        peers.sendData(outgoing.data, transferID: transferID)
    }

    public func dataChannelFailed(transferID: String) {
        guard let outgoing, outgoing.transferID == transferID else { return }
        self.outgoing = nil
        setStatus(.sendFailed(fileName: outgoing.fileName, reason: .connectionFailed))
    }

    public func dataChannelClosed(transferID: String) {
        if let outgoing, outgoing.transferID == transferID {
            // 받는 쪽은 다 받으면 채널을 닫는다. 그 전에 끊겼는지는 이번 단계에서 구분하지 않는다(#19에서 진행률로 다룬다).
            self.outgoing = nil
            setStatus(outgoing.channelOpened ? .sent(fileName: outgoing.fileName)
                                             : .sendFailed(fileName: outgoing.fileName, reason: .connectionFailed))
        }
        if let receiving, receiving.offer.transferID == transferID {
            self.receiving = nil
            setStatus(.receiveFailed(fileName: receiving.offer.fileName, reason: .interrupted))
        }
    }

    // MARK: 내부

    private func clearPending() {
        guard let pending else { return }
        self.pending = nil
        incomingOffer = nil
        notifier.removeOffer(transferID: pending.offer.transferID)
    }

    private func setStatus(_ status: Status) {
        self.status = status
        onChange?()
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
