import CryptoKit
import Foundation
import os

/// 파일을 상대 Mac으로 보내고 받는다.
///
/// 제안(`fileOffer`)·답(`fileAnswer`)·결과(`fileEnd`)는 제어 연결로 주고받고, 파일 바이트는 전송마다 새로 여는
/// 데이터 채널로 보낸다. 큰 파일이 한/영 동기화나 세션 신호를 막지 않게 하기 위해서다. 받는 쪽은 매번 수락해야 한다.
/// 원격 세션 여부와 무관하게 피어가 연결돼 있으면 보낼 수 있다.
///
/// 데이터 채널에는 파일 바이트 `size`개 뒤에 SHA-256(32바이트)을 붙인다. 보내는 쪽은 조각 단위로 읽으면서 계산하고,
/// 전송 계층이 앞 조각을 넘겼다고 알릴 때(`dataChannelSent`)만 다음 조각을 보낸다(최대 `sendWindow`개).
/// 받는 쪽은 임시 파일에 이어 쓰면서 계산하고, 끝에 맞춰 본 뒤에야 최종 이름으로 바꾼다.
/// 그래서 메모리 사용량은 파일 크기와 무관하다.
///
/// 수락한 전송의 끝은 `fileEnd`로 서로 알린다. 받는 쪽은 저장·실패·취소를, 보내는 쪽은 취소·중단을 보낸다.
/// 보내는 쪽의 "보냄"은 받는 쪽이 저장했다고 알린 뒤에만 표시한다.
///
/// 스레드: 메인 스레드 전용 (PeerManager와 같다).
public final class FileTransferController: PeerDataChannelHandling {
    public enum SendFailure: Equatable {
        case peerNeedsUpdate        // 상대가 파일 전송 기능을 알리지 않음
        case readFailed             // 파일을 열거나 읽지 못함
        case noPeer
        case noAnswer               // 받는 쪽에서 답이 오지 않음
        case connectionFailed       // 피어 연결이 끊기거나 데이터 채널을 열지 못함
        case interrupted            // 보내는 중 데이터 채널이 끊기거나 멈춤
        case peerVerificationFailed // 받는 쪽 검증 실패
        case peerSaveFailed         // 받는 쪽 저장 실패
        case noConfirmation         // 다 보냈지만 받는 쪽 결과가 오지 않음
    }

    public enum ReceiveFailure: Equatable {
        case timedOut           // 60초 안에 응답하지 않아 거절함
        case checksumMismatch   // SHA-256이 맞지 않거나 크기를 넘게 옴
        case saveFailed         // 임시 파일을 만들거나 쓰거나 최종 이름으로 바꾸지 못함
        case interrupted        // 다 받기 전에 데이터 채널이 끊기거나 멈춤
    }

    /// 전송량. `done`은 보내는 쪽이면 네트워크 스택에 넘긴 바이트, 받는 쪽이면 임시 파일에 쓴 바이트.
    public struct Progress: Equatable {
        public let done: Int
        public let total: Int
        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
        /// 0...100. 빈 파일은 100.
        public var percent: Int { total <= 0 ? 100 : done * 100 / total }
    }

    /// 메뉴 표시용 전송 상태. 보내기와 받기는 따로 둔다(동시에 진행될 수 있다).
    public enum Status: Equatable {
        case none
        case waitingForAnswer(fileName: String, peerName: String)
        /// 진행률이 100%면 받는 쪽 확인을 기다리는 중이다.
        case sending(fileName: String, progress: Progress)
        case sent(fileName: String)
        case declined(fileName: String, reason: FileDeclineReason)
        case sendFailed(fileName: String, reason: SendFailure)
        case receiving(fileName: String, progress: Progress)
        /// `fileName`은 실제로 저장한 이름.
        case received(fileName: String)
        case receiveFailed(fileName: String, reason: ReceiveFailure)
        case canceled(fileName: String, byPeer: Bool)
    }

    static let log = Logger(subsystem: "com.jeongsk.VNCAutoResolution", category: "filetransfer")

    /// 받는 쪽이 제안에 답해야 하는 시간(초). 넘기면 거절한다. 수락한 뒤 데이터가 이만큼 오가지 않아도 중단한다.
    public let answerTimeout: TimeInterval
    /// 보내는 쪽이 답을 기다리는 시간(초). 받는 쪽의 시간 초과 거절이 먼저 오도록 여유를 둔다.
    public let senderWaitTimeout: TimeInterval
    /// 한 번에 읽어 보내는 조각 크기(바이트).
    public let chunkSize: Int
    /// 전송 계층이 넘겼다고 알리기 전까지 보내 둘 수 있는 조각 수.
    public let sendWindow: Int

    public private(set) var sendStatus: Status = .none
    public private(set) var receiveStatus: Status = .none
    /// 사용자의 응답을 기다리는 받은 제안. 한 번에 하나만 둔다.
    public private(set) var incomingOffer: IncomingFileOffer?
    /// 상태가 바뀔 때마다 불린다. 진행률은 퍼센트가 바뀔 때만 알린다.
    public var onChange: (() -> Void)?

    private final class Outgoing {
        enum Phase {
            case offered    // 답을 기다림
            case accepted   // 데이터 채널이 열리기를 기다림
            case streaming
            case drained    // 마지막 바이트까지 넘김. 받는 쪽 결과를 기다림
        }
        let transferID: String
        let deviceID: String
        let fileName: String
        let file: FileReadHandle
        var phase = Phase.offered
        var lastActivity: Date
        var hasher = SHA256()
        /// 읽어서 보낸 파일 바이트.
        var queued = 0
        var digestQueued = false
        /// 보냈지만 아직 넘겼다는 알림이 오지 않은 조각 크기(보낸 순서).
        var inFlight: [Int] = []
        /// 넘겼다고 알림이 온 바이트(끝의 SHA-256 포함).
        var acknowledged = 0
        var channelClosed = false

        init(transferID: String, deviceID: String, fileName: String, file: FileReadHandle, now: Date) {
            self.transferID = transferID
            self.deviceID = deviceID
            self.fileName = fileName
            self.file = file
            self.lastActivity = now
        }
        var size: Int { file.size }
        var progress: Progress { Progress(done: min(acknowledged, size), total: size) }
    }

    private struct PendingOffer {
        let offer: IncomingFileOffer
        let receivedAt: Date
    }

    private final class Receiving {
        let offer: IncomingFileOffer
        /// 수락한 시각, 채널이 열린 뒤에는 마지막으로 바이트를 받은 시각.
        var lastActivity: Date
        /// 데이터 채널이 열리면 만든다.
        var file: PartialFile?
        var hasher = SHA256()
        var written = 0
        /// 파일 바이트 뒤에 온 바이트(SHA-256).
        var digest = Data()

        init(offer: IncomingFileOffer, now: Date) {
            self.offer = offer
            self.lastActivity = now
        }
        var progress: Progress { Progress(done: written, total: offer.size) }
    }

    /// 끝낸 전송. 상대의 `fileEnd`가 늦게 오면 그 판정으로 바꾼다(제어 연결과 데이터 채널은 도착 순서가 다르다).
    private struct Finished {
        let transferID: String
        let deviceID: String
        let fileName: String

        func matches(_ transferID: String, _ deviceID: String) -> Bool {
            self.transferID == transferID && self.deviceID == deviceID
        }
    }

    private static let digestBytes = 32

    private let reader: LocalFileReading
    private let store: ReceivedFileStoring
    private let notifier: FileOfferNotifying
    private let settings: FileTransferSettingsStoring
    private let peers: PeerManager
    private let clock: Clock

    private var outgoing: Outgoing?
    private var pending: PendingOffer?
    private var receiving: Receiving?
    private var lastSent: Finished?
    private var lastReceived: Finished?

    public init(
        reader: LocalFileReading,
        store: ReceivedFileStoring,
        notifier: FileOfferNotifying,
        settings: FileTransferSettingsStoring,
        peers: PeerManager,
        clock: Clock,
        answerTimeout: TimeInterval = 60,
        senderWaitTimeout: TimeInterval = 80,
        chunkSize: Int = 256 * 1024,
        sendWindow: Int = 4
    ) {
        self.reader = reader
        self.store = store
        self.notifier = notifier
        self.settings = settings
        self.peers = peers
        self.clock = clock
        self.answerTimeout = answerTimeout
        self.senderWaitTimeout = senderWaitTimeout
        self.chunkSize = chunkSize
        self.sendWindow = sendWindow
    }

    // MARK: 상태

    public var receiveEnabled: Bool {
        get { settings.fileReceiveEnabled }
        set { settings.fileReceiveEnabled = newValue; onChange?() }
    }

    /// 보내는 중인 전송(답 대기 포함)이 있는지.
    public var isSending: Bool { outgoing != nil }
    /// 보내기를 취소할 수 있는지. 마지막 바이트까지 넘긴 뒤에는 받는 쪽이 저장했을 수 있으므로 취소하지 않는다.
    public var canCancelSend: Bool { outgoing.map { $0.phase != .drained } ?? false }
    /// 받는 중인 전송(수락 후)이 있는지.
    public var isReceiving: Bool { receiving != nil }

    /// 이 피어가 파일 전송 기능을 알렸는지.
    public func canSend(to peer: PeerManager.Peer) -> Bool {
        peer.features.contains(PeerFeature.fileTransfer)
    }

    // MARK: 보내기

    /// 파일을 이 피어에게 보내자고 제안한다. 보내던 전송이 있으면 취소한다.
    public func send(fileAt url: URL, to deviceID: String) {
        let fileName = url.lastPathComponent
        guard let peer = peers.peers.first(where: { $0.deviceID == deviceID }) else {
            return setSendStatus(.sendFailed(fileName: fileName, reason: .noPeer))
        }
        guard canSend(to: peer) else { return setSendStatus(.sendFailed(fileName: fileName, reason: .peerNeedsUpdate)) }
        let file: FileReadHandle
        do {
            file = try reader.open(url)
        } catch {
            return setSendStatus(.sendFailed(fileName: fileName, reason: .readFailed))
        }
        if let outgoing {
            finishSend(outgoing, .canceled(fileName: outgoing.fileName, byPeer: false), tell: .canceled)
        }

        let transfer = Outgoing(transferID: UUID().uuidString, deviceID: deviceID, fileName: fileName, file: file,
                                now: clock.now)
        outgoing = transfer
        Self.log.debug("offer \(transfer.transferID, privacy: .public): \(file.size, privacy: .public)바이트")
        peers.send(.fileOffer(deviceID: peers.deviceID, transferID: transfer.transferID, name: fileName, size: file.size),
                   toDeviceID: deviceID)
        setSendStatus(.waitingForAnswer(fileName: fileName, peerName: peer.name))
    }

    /// 보내는 전송을 취소한다(답 대기 중이어도). 상대도 취소 상태가 된다.
    public func cancelSend() {
        guard canCancelSend, let outgoing else { return }
        finishSend(outgoing, .canceled(fileName: outgoing.fileName, byPeer: false), tell: .canceled)
    }

    /// 보낼 수 있는 만큼(`sendWindow`) 다음 조각을 읽어 보낸다. 파일 바이트를 다 보내면 SHA-256을 붙인다.
    private func pump(_ transfer: Outgoing) {
        while transfer.phase == .streaming, !transfer.channelClosed, transfer.inFlight.count < sendWindow {
            let chunk: Data
            if transfer.queued < transfer.size {
                do {
                    chunk = try transfer.file.read(upTo: min(chunkSize, transfer.size - transfer.queued))
                } catch {
                    return finishSend(transfer, .sendFailed(fileName: transfer.fileName, reason: .readFailed),
                                      tell: .interrupted)
                }
                // 보내는 중 파일이 줄었다.
                guard !chunk.isEmpty else {
                    return finishSend(transfer, .sendFailed(fileName: transfer.fileName, reason: .readFailed),
                                      tell: .interrupted)
                }
                transfer.hasher.update(data: chunk)
                transfer.queued += chunk.count
            } else if !transfer.digestQueued {
                chunk = Data(transfer.hasher.finalize())
                transfer.digestQueued = true
            } else {
                return
            }
            transfer.inFlight.append(chunk.count)
            peers.sendData(chunk, transferID: transfer.transferID)
        }
    }

    /// 보내기를 끝낸다. `tell`이 있으면 상대에게 `fileEnd`로 알린다.
    private func finishSend(_ transfer: Outgoing, _ status: Status, tell result: FileEndResult?) {
        if let result {
            peers.send(.fileEnd(deviceID: peers.deviceID, transferID: transfer.transferID, result: result),
                       toDeviceID: transfer.deviceID)
        }
        peers.closeDataChannel(transferID: transfer.transferID)
        transfer.file.close()
        outgoing = nil
        lastSent = Finished(transferID: transfer.transferID, deviceID: transfer.deviceID, fileName: transfer.fileName)
        setSendStatus(status)
    }

    /// 받는 쪽이 알린 결과에 해당하는 보내는 쪽 상태.
    private static func senderStatus(after result: FileEndResult, fileName: String) -> Status {
        switch result {
        case .saved: return .sent(fileName: fileName)
        case .canceled: return .canceled(fileName: fileName, byPeer: true)
        case .checksumMismatch: return .sendFailed(fileName: fileName, reason: .peerVerificationFailed)
        case .saveFailed: return .sendFailed(fileName: fileName, reason: .peerSaveFailed)
        case .interrupted: return .sendFailed(fileName: fileName, reason: .interrupted)
        }
    }

    // MARK: 받기: 사용자 응답

    public func accept(transferID: String) {
        guard let pending, pending.offer.transferID == transferID else { return }
        clearPending()
        let transfer = Receiving(offer: pending.offer, now: clock.now)
        receiving = transfer
        peers.send(.fileAnswer(deviceID: peers.deviceID, transferID: transferID, accepted: true, reason: nil,
                               port: peers.listenPort.map(Int.init)),
                   toDeviceID: pending.offer.deviceID)
        setReceiveStatus(.receiving(fileName: pending.offer.fileName, progress: transfer.progress))
    }

    public func decline(transferID: String) {
        guard let pending, pending.offer.transferID == transferID else { return }
        clearPending()
        answer(pending.offer.deviceID, transferID, declined: .declined)
        onChange?()
    }

    /// 받는 전송을 취소한다. 임시 파일을 지우고, 상대도 취소 상태가 된다.
    public func cancelReceive() {
        guard let receiving else { return }
        endReceive(receiving, .canceled(fileName: receiving.offer.fileName, byPeer: false), tell: .canceled)
    }

    /// 받기를 끝낸다. 저장하지 않았으면 임시 파일을 지운다. `tell`이 있으면 상대에게 `fileEnd`로 알린다.
    private func endReceive(_ transfer: Receiving, _ status: Status, tell result: FileEndResult?, keepFile: Bool = false) {
        if !keepFile { transfer.file?.discard() }
        peers.closeDataChannel(transferID: transfer.offer.transferID)
        if let result {
            peers.send(.fileEnd(deviceID: peers.deviceID, transferID: transfer.offer.transferID, result: result),
                       toDeviceID: transfer.offer.deviceID)
        }
        receiving = nil
        lastReceived = Finished(transferID: transfer.offer.transferID, deviceID: transfer.offer.deviceID,
                                fileName: transfer.offer.fileName)
        setReceiveStatus(status)
    }

    // MARK: 메시지

    /// 피어가 보낸 `fileOffer`/`fileAnswer`/`fileEnd`를 처리한다.
    public func handle(_ message: PeerMessage, from peer: PeerManager.Peer) {
        switch message {
        case .fileOffer(_, let transferID, let name, let size):
            receiveOffer(transferID: transferID, name: name, size: size, from: peer)
        case .fileAnswer(_, let transferID, let accepted, let reason, let port):
            receiveAnswer(transferID: transferID, accepted: accepted, reason: reason, port: port, from: peer)
        case .fileEnd(_, let transferID, let result):
            receiveEnd(transferID: transferID, result: result, from: peer)
        default:
            break
        }
    }

    private func receiveOffer(transferID: String, name: String, size: Int, from peer: PeerManager.Peer) {
        guard receiveEnabled else { return answer(peer.deviceID, transferID, declined: .disabled) }
        guard size >= 0 else { return answer(peer.deviceID, transferID, declined: .declined) }
        if let free = store.availableBytes(), size > free {
            return answer(peer.deviceID, transferID, declined: .noSpace)
        }
        guard pending == nil, receiving == nil else { return answer(peer.deviceID, transferID, declined: .busy) }
        let offer = IncomingFileOffer(
            transferID: transferID, deviceID: peer.deviceID, peerName: peer.name,
            fileName: FileNames.sanitize(name), size: size)
        pending = PendingOffer(offer: offer, receivedAt: clock.now)
        incomingOffer = offer
        notifier.showOffer(offer)
        onChange?()
    }

    private func receiveAnswer(transferID: String, accepted: Bool, reason: FileDeclineReason?, port: Int?,
                               from peer: PeerManager.Peer) {
        guard let outgoing, outgoing.transferID == transferID, outgoing.deviceID == peer.deviceID,
              outgoing.phase == .offered else { return }
        guard accepted else {
            return finishSend(outgoing, .declined(fileName: outgoing.fileName, reason: reason ?? .declined), tell: nil)
        }
        outgoing.phase = .accepted
        outgoing.lastActivity = clock.now
        let listenPort = port.flatMap { UInt16(exactly: $0) }
        guard peers.openDataChannel(toDeviceID: peer.deviceID, port: listenPort, transferID: transferID) else {
            return finishSend(outgoing, .sendFailed(fileName: outgoing.fileName, reason: .connectionFailed), tell: nil)
        }
        setSendStatus(.sending(fileName: outgoing.fileName, progress: outgoing.progress))
    }

    private func receiveEnd(transferID: String, result: FileEndResult, from peer: PeerManager.Peer) {
        // 보내는 전송: 받는 쪽의 결과.
        if let outgoing, outgoing.transferID == transferID, outgoing.deviceID == peer.deviceID {
            return finishSend(outgoing, Self.senderStatus(after: result, fileName: outgoing.fileName), tell: nil)
        }
        // 받는 전송: 보내는 쪽이 취소하거나 중단함.
        func byPeer(_ fileName: String) -> Status {
            result == .canceled ? .canceled(fileName: fileName, byPeer: true)
                                : .receiveFailed(fileName: fileName, reason: .interrupted)
        }
        if let receiving, receiving.offer.transferID == transferID, receiving.offer.deviceID == peer.deviceID {
            return endReceive(receiving, byPeer(receiving.offer.fileName), tell: nil)
        }
        if let pending, pending.offer.transferID == transferID, pending.offer.deviceID == peer.deviceID {
            clearPending()
            return setReceiveStatus(byPeer(pending.offer.fileName))
        }
        // 이미 끝낸 전송: 우리가 짐작한 결과(끊김·확인 없음)는 상대의 판정으로 바꾼다.
        // 받는 쪽이 저장했다면 우리가 취소했더라도(취소가 저장보다 늦게 닿음) "보냄"으로 맞춘다.
        if let lastSent, lastSent.matches(transferID, peer.deviceID) {
            let guessed: Bool
            switch sendStatus {
            case .sendFailed(_, let reason): guessed = [.interrupted, .noConfirmation, .connectionFailed].contains(reason)
            case .canceled(_, byPeer: false): guessed = result == .saved
            default: guessed = false
            }
            if guessed { setSendStatus(Self.senderStatus(after: result, fileName: lastSent.fileName)) }
        }
        if let lastReceived, lastReceived.matches(transferID, peer.deviceID), result == .canceled,
           receiveStatus == .receiveFailed(fileName: lastReceived.fileName, reason: .interrupted) {
            setReceiveStatus(.canceled(fileName: lastReceived.fileName, byPeer: true))
        }
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
            setReceiveStatus(.receiveFailed(fileName: pending.offer.fileName, reason: .timedOut))
        }
        // 데이터 채널이 오지 않거나, 열린 뒤 바이트가 끊기면 정리한다. (그대로 두면 새 제안을 계속 busy로 거절한다)
        if let receiving, now.timeIntervalSince(receiving.lastActivity) >= answerTimeout {
            endReceive(receiving, .receiveFailed(fileName: receiving.offer.fileName, reason: .interrupted),
                       tell: .interrupted)
        }
        if let outgoing {
            let idle = now.timeIntervalSince(outgoing.lastActivity)
            switch outgoing.phase {
            case .offered where idle >= senderWaitTimeout:
                finishSend(outgoing, .sendFailed(fileName: outgoing.fileName, reason: .noAnswer), tell: nil)
            case .accepted where idle >= answerTimeout, .streaming where idle >= answerTimeout:
                finishSend(outgoing, .sendFailed(fileName: outgoing.fileName, reason: .interrupted), tell: .interrupted)
            case .drained where idle >= answerTimeout:
                finishSend(outgoing, .sendFailed(fileName: outgoing.fileName, reason: .noConfirmation), tell: nil)
            default:
                break
            }
        }
    }

    /// 피어 목록이 바뀌었을 때 부른다. 끊긴 피어와 주고받던 전송을 정리한다. (결과를 알릴 길이 없으므로 알리지 않는다)
    public func peersChanged() {
        let connected = Set(peers.peers.map(\.deviceID))
        if let pending, !connected.contains(pending.offer.deviceID) {
            clearPending()
            onChange?()
        }
        if let receiving, !connected.contains(receiving.offer.deviceID) {
            endReceive(receiving, .receiveFailed(fileName: receiving.offer.fileName, reason: .interrupted), tell: nil)
        }
        if let outgoing, !connected.contains(outgoing.deviceID) {
            finishSend(outgoing, .sendFailed(fileName: outgoing.fileName, reason: .connectionFailed), tell: nil)
        }
    }

    // MARK: PeerDataChannelHandling

    public func shouldAcceptDataChannel(transferID: String, from deviceID: String) -> Bool {
        guard let receiving, receiving.offer.transferID == transferID, receiving.offer.deviceID == deviceID,
              receiving.file == nil else { return false }
        do {
            receiving.file = try store.beginFile()
        } catch {
            Self.log.error("recv \(transferID, privacy: .public): 임시 파일 실패 \(error.localizedDescription, privacy: .public)")
            endReceive(receiving, .receiveFailed(fileName: receiving.offer.fileName, reason: .saveFailed), tell: .saveFailed)
            return false
        }
        receiving.lastActivity = clock.now
        return true
    }

    public func dataChannelReceived(transferID: String, data: Data) {
        guard let transfer = receiving, transfer.offer.transferID == transferID, let file = transfer.file else { return }
        transfer.lastActivity = clock.now
        let fileName = transfer.offer.fileName
        let fileBytes = data.prefix(transfer.offer.size - transfer.written)
        if !fileBytes.isEmpty {
            do {
                try file.write(fileBytes)
            } catch {
                Self.log.error("recv \(transferID, privacy: .public): 쓰기 실패 \(error.localizedDescription, privacy: .public)")
                return endReceive(transfer, .receiveFailed(fileName: fileName, reason: .saveFailed), tell: .saveFailed)
            }
            transfer.hasher.update(data: fileBytes)
            transfer.written += fileBytes.count
            setReceiveProgress(.receiving(fileName: fileName, progress: transfer.progress))
        }
        transfer.digest.append(data.dropFirst(fileBytes.count))
        guard transfer.digest.count >= Self.digestBytes else { return }

        // 끝까지 받았다(넘쳤으면 검증 실패). 받는 쪽이 채널을 닫는다.
        guard transfer.digest == Data(transfer.hasher.finalize()) else {
            Self.log.error("recv \(transferID, privacy: .public): 검증 실패")
            return endReceive(transfer, .receiveFailed(fileName: fileName, reason: .checksumMismatch),
                              tell: .checksumMismatch)
        }
        do {
            let saved = try file.commit(preferredName: fileName)
            endReceive(transfer, .received(fileName: saved), tell: .saved, keepFile: true)
        } catch {
            Self.log.error("recv \(transferID, privacy: .public): 저장 실패 \(error.localizedDescription, privacy: .public)")
            endReceive(transfer, .receiveFailed(fileName: fileName, reason: .saveFailed), tell: .saveFailed)
        }
    }

    public func dataChannelOpened(transferID: String) {
        guard let outgoing, outgoing.transferID == transferID, outgoing.phase == .accepted else {
            peers.closeDataChannel(transferID: transferID)
            return
        }
        outgoing.phase = .streaming
        outgoing.lastActivity = clock.now
        pump(outgoing)
    }

    public func dataChannelSent(transferID: String) {
        guard let outgoing, outgoing.transferID == transferID, !outgoing.inFlight.isEmpty else { return }
        outgoing.acknowledged += outgoing.inFlight.removeFirst()
        outgoing.lastActivity = clock.now
        if outgoing.digestQueued, outgoing.inFlight.isEmpty { outgoing.phase = .drained }
        setSendProgress(.sending(fileName: outgoing.fileName, progress: outgoing.progress))
        pump(outgoing)
    }

    public func dataChannelFailed(transferID: String) {
        guard let outgoing, outgoing.transferID == transferID else { return }
        finishSend(outgoing, .sendFailed(fileName: outgoing.fileName, reason: .connectionFailed), tell: .interrupted)
    }

    public func dataChannelClosed(transferID: String) {
        // 보내는 쪽: 받는 쪽이 다 받았거나, 취소·실패해 닫았다. 결과는 `fileEnd`로 온다(늦으면 시간 초과).
        if let outgoing, outgoing.transferID == transferID {
            outgoing.channelClosed = true
            outgoing.lastActivity = clock.now
        }
        if let receiving, receiving.offer.transferID == transferID {
            endReceive(receiving, .receiveFailed(fileName: receiving.offer.fileName, reason: .interrupted),
                       tell: .interrupted)
        }
    }

    // MARK: 내부

    private func clearPending() {
        guard let pending else { return }
        self.pending = nil
        incomingOffer = nil
        notifier.removeOffer(transferID: pending.offer.transferID)
    }

    private func setSendStatus(_ status: Status) {
        sendStatus = status
        onChange?()
    }

    private func setReceiveStatus(_ status: Status) {
        receiveStatus = status
        onChange?()
    }

    /// 진행률은 퍼센트가 바뀔 때만 알린다(조각마다 메뉴를 다시 그리지 않는다).
    private func setSendProgress(_ status: Status) {
        let changed = Self.percent(sendStatus) != Self.percent(status)
        sendStatus = status
        if changed { onChange?() }
    }

    private func setReceiveProgress(_ status: Status) {
        let changed = Self.percent(receiveStatus) != Self.percent(status)
        receiveStatus = status
        if changed { onChange?() }
    }

    private static func percent(_ status: Status) -> Int? {
        switch status {
        case .sending(_, let progress), .receiving(_, let progress): return progress.percent
        default: return nil
        }
    }
}
