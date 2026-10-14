import Foundation

/// 피어 레지스트리 + 프로토콜 처리. 전송 포트가 올려 주는 바이트를 메시지로 분리·검증하고,
/// hello로 피어를 식별해 deviceID 기준으로 중복을 정리한다.
///
/// 스레드: 단일 스레드(또는 직렬 큐)에서만 쓴다. 앱에서는 메인 스레드.
/// 전송 이벤트는 `handle(_:)`로 넘겨 준다(연결은 앱/테스트가 한다).
public final class PeerManager {
    /// hello까지 마친, 메시지를 주고받을 수 있는 피어.
    public struct Peer: Equatable, Identifiable {
        public let deviceID: String
        public let name: String
        public let route: PeerRoute
        /// hello로 알린 지원 기능(`PeerFeature`).
        public let features: Set<String>
        public var id: String { deviceID }
    }

    /// 비정상 피어 방어 한도.
    public struct Limits {
        /// 메시지 한 줄 상한. 클립보드 텍스트 상한에 JSON 이스케이프 최악의 경우(제어 문자 1바이트 → `\u00XX` 6바이트)와
        /// 나머지 필드를 더한 크기다. 상한 안의 클립보드는 어떤 내용이든 한 줄에 들어간다.
        public var maxMessageBytes = PeerMessage.maxClipboardTextBytes * 6 + 4096
        public var maxMessagesPerWindow = 200
        public var window: TimeInterval = 1
        public var maxNameLength = 100
        public init() {}
    }

    /// 연결이 받은 바이트를 어떻게 다루는지.
    private enum Mode {
        /// 첫 줄을 기다리는 중. 첫 줄로 피어 연결(hello)인지 데이터 채널인지 가른다.
        case firstLine(Data)
        /// 줄 단위 메시지.
        case lines
        /// 데이터 채널: 바이트를 그대로 넘긴다(프레이밍·빈도 제한 없음).
        case dataChannel(transferID: String)
    }

    private struct Connection {
        let id: PeerConnectionID
        let isOutbound: Bool
        /// 우리가 건 연결이면 우리가 쓴 경로.
        let outboundRoute: PeerRoute?
        var framer: MessageFramer
        var limiter: RateLimiter
        var peer: Peer?
        var mode: Mode = .firstLine(Data())
        /// 우리가 연 데이터 채널에서 머리말의 `dataSent`가 아직 오지 않았는지. 머리말은 `sendData`로 보낸 게 아니다.
        var awaitingHeaderSent = false
    }

    /// 첫 줄(hello 또는 데이터 채널 머리말) 상한. 둘 다 짧다.
    static let maxFirstLineBytes = 4096

    public let deviceID: String
    public let deviceName: String

    /// 연결된 피어 목록(이름순). 메뉴에 표시한다.
    public var peers: [Peer] {
        connections.values.compactMap(\.peer).sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    /// 전송 계층 상태/오류 문구. 비어 있으면 정상.
    public private(set) var statusMessage = ""
    /// 한도를 넘거나 형식이 틀려 무시한 메시지 수. (진단용)
    public private(set) var ignoredMessageCount = 0

    /// 피어 목록/상태가 바뀔 때마다 불린다.
    public var onChange: (() -> Void)?
    /// hello 이후 피어가 보낸 `input`/`session`/`display`/`clipboard`/`fileOffer`/`fileAnswer`/`fileEnd` 메시지. 코어(AppCore)가 구독한다.
    public var onMessage: ((PeerMessage, Peer) -> Void)?
    /// 데이터 채널 이벤트를 받는 쪽(파일 전송).
    public weak var dataChannelHandler: PeerDataChannelHandling?
    /// 우리 리스너 포트. 전송 계층이 알려 준 뒤에 정해진다.
    public private(set) var listenPort: UInt16?

    private let transport: PeerTransporting
    private let settings: PeerSettingsStoring
    private let secrets: PassphraseStoring
    private let clock: Clock
    private let limits: Limits
    private var connections: [PeerConnectionID: Connection] = [:]

    public init(
        deviceName: String,
        transport: PeerTransporting,
        settings: PeerSettingsStoring,
        secrets: PassphraseStoring,
        clock: Clock,
        limits: Limits = Limits()
    ) {
        self.deviceID = settings.deviceID
        self.deviceName = deviceName
        self.transport = transport
        self.settings = settings
        self.secrets = secrets
        self.clock = clock
        self.limits = limits
    }

    // MARK: 설정

    public var passphrase: String { secrets.passphrase ?? "" }
    public var manualAddress: String { settings.manualPeerAddress }

    /// 저장된 설정을 전송 계층에 반영한다. 앱 시작 시 한 번 부른다.
    public func applyStoredConfig() {
        transport.updateConfig(PeerTransportConfig(
            passphrase: passphrase,
            manualAddress: manualAddress.isEmpty ? nil : manualAddress
        ))
    }

    /// 설정 창에서 저장: 암호(Keychain)와 직접 연결 주소를 저장하고 전송 계층에 반영한다.
    public func savePairing(passphrase: String, manualAddress: String) {
        secrets.passphrase = passphrase.isEmpty ? nil : passphrase
        settings.manualPeerAddress = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        applyStoredConfig()
    }

    // MARK: 보내기

    /// 연결된 모든 피어에게 보낸다.
    public func broadcast(_ message: PeerMessage) {
        broadcast(message, where: { _ in true })
    }

    /// 조건에 맞는 피어에게만 보낸다. (예: 기능을 지원하는 피어)
    public func broadcast(_ message: PeerMessage, where include: (Peer) -> Bool) {
        let data = PeerCodec.encode(message)
        for connection in connections.values {
            guard let peer = connection.peer, include(peer) else { continue }
            transport.send(data, to: connection.id)
        }
    }

    /// 이 deviceID의 피어에게만 보낸다. 연결돼 있지 않으면 false.
    @discardableResult
    public func send(_ message: PeerMessage, toDeviceID peerID: String) -> Bool {
        guard let connection = peerConnection(for: peerID) else { return false }
        transport.send(PeerCodec.encode(message), to: connection.id)
        return true
    }

    // MARK: 데이터 채널

    /// 이 피어에게 데이터 채널을 연다. 결과는 `dataChannelHandler`로 온다. 피어가 없으면 false.
    @discardableResult
    public func openDataChannel(toDeviceID peerID: String, port: UInt16?, transferID: String) -> Bool {
        guard let connection = peerConnection(for: peerID) else { return false }
        transport.openDataChannel(alongside: connection.id, port: port, transferID: transferID)
        return true
    }

    /// 데이터 채널로 바이트를 보낸다.
    public func sendData(_ data: Data, transferID: String) {
        guard let id = dataChannelID(transferID) else { return }
        transport.send(data, to: id)
    }

    /// 데이터 채널을 닫는다. `dataChannelClosed`는 부르지 않는다.
    public func closeDataChannel(transferID: String) {
        guard let id = dataChannelID(transferID) else { return }
        connections.removeValue(forKey: id)
        transport.close(id)
    }

    private func peerConnection(for peerID: String) -> Connection? {
        connections.values.first { $0.peer?.deviceID == peerID }
    }

    private func dataChannelID(_ transferID: String) -> PeerConnectionID? {
        connections.values.first {
            if case .dataChannel(let id) = $0.mode { return id == transferID } else { return false }
        }?.id
    }

    // MARK: 전송 이벤트

    public func handle(_ event: PeerTransportEvent) {
        switch event {
        case .connected(let id, let route, let isOutbound):
            connections[id] = Connection(
                id: id,
                isOutbound: isOutbound,
                outboundRoute: isOutbound ? route : nil,
                framer: MessageFramer(maxLineLength: limits.maxMessageBytes),
                limiter: RateLimiter(maxCount: limits.maxMessagesPerWindow, interval: limits.window)
            )
            transport.send(PeerCodec.encode(.hello(
                deviceID: deviceID,
                name: deviceName,
                protocolVersion: PeerMessage.protocolVersion,
                route: isOutbound ? route : nil,
                features: PeerFeature.supported
            )), to: id)

        case .received(let id, let data):
            guard let connection = connections[id] else { return }
            switch connection.mode {
            case .firstLine(let buffered):
                receiveFirstLine(buffered + data, on: id)
            case .lines:
                receiveLines(data, on: id)
            case .dataChannel(let transferID):
                // 우리가 연 데이터 채널로 상대가 보낸 바이트(hello 등)는 쓰지 않는다.
                if !connection.isOutbound { dataChannelHandler?.dataChannelReceived(transferID: transferID, data: data) }
            }

        case .disconnected(let id):
            guard let removed = connections.removeValue(forKey: id) else { return }
            if case .dataChannel(let transferID) = removed.mode {
                dataChannelHandler?.dataChannelClosed(transferID: transferID)
            } else if removed.peer != nil {
                onChange?()
            }

        case .status(let text):
            statusMessage = text
            onChange?()

        case .listening(let port):
            listenPort = port

        case .dataChannelOpened(let id, let transferID):
            var channel = Connection(
                id: id, isOutbound: true, outboundRoute: nil,
                framer: MessageFramer(maxLineLength: 0), limiter: RateLimiter(maxCount: 0, interval: 1))
            channel.mode = .dataChannel(transferID: transferID)
            channel.awaitingHeaderSent = true
            connections[id] = channel
            transport.send(PeerCodec.encode(.dataChannel(deviceID: deviceID, transferID: transferID)), to: id)
            dataChannelHandler?.dataChannelOpened(transferID: transferID)

        case .dataChannelFailed(let transferID):
            dataChannelHandler?.dataChannelFailed(transferID: transferID)

        case .dataSent(let id):
            guard let connection = connections[id], connection.isOutbound,
                  case .dataChannel(let transferID) = connection.mode else { return }
            // 첫 번째는 머리말 몫이다(보낸 순서대로 온다).
            guard !connection.awaitingHeaderSent else {
                connections[id]?.awaitingHeaderSent = false
                return
            }
            dataChannelHandler?.dataChannelSent(transferID: transferID)
        }
    }

    /// 첫 줄을 모은다. 데이터 채널 머리말이면 그 연결을 데이터 채널로 바꾸고 나머지 바이트를 그대로 넘긴다.
    /// 그 밖에는 줄 단위 처리로 넘긴다. (머리말과 파일 바이트가 한 덩어리로 와도 파일 바이트를 줄로 자르지 않는다)
    private func receiveFirstLine(_ buffered: Data, on id: PeerConnectionID) {
        guard let newline = buffered.firstIndex(of: 0x0A) else {
            guard buffered.count <= Self.maxFirstLineBytes else { ignoredMessageCount += 1; return drop(id) }
            connections[id]?.mode = .firstLine(buffered)
            return
        }
        let line = buffered[buffered.startIndex..<newline]
        let rest = buffered[buffered.index(after: newline)...]
        guard line.count <= Self.maxFirstLineBytes else { ignoredMessageCount += 1; return drop(id) }

        if case .dataChannel(let peerID, let transferID)? = PeerCodec.decode(line) {
            guard connections[id]?.isOutbound == false, peerID != deviceID,
                  dataChannelHandler?.shouldAcceptDataChannel(transferID: transferID, from: peerID) == true else {
                ignoredMessageCount += 1
                return drop(id)
            }
            connections[id]?.mode = .dataChannel(transferID: transferID)
            if !rest.isEmpty { dataChannelHandler?.dataChannelReceived(transferID: transferID, data: Data(rest)) }
            return
        }
        connections[id]?.mode = .lines
        receiveLines(Data(line) + [0x0A] + rest, on: id)
    }

    private func receiveLines(_ data: Data, on id: PeerConnectionID) {
        guard var connection = connections[id] else { return }
        let lines = connection.framer.append(data)
        connections[id] = connection
        for line in lines {
            // 위 처리 중 연결이 닫혔을 수 있다(중복/자기 자신 정리).
            guard connections[id] != nil else { return }
            guard connections[id]!.limiter.allow(at: clock.now) else {
                ignoredMessageCount += 1
                continue
            }
            guard let message = PeerCodec.decode(line) else {
                ignoredMessageCount += 1
                continue
            }
            handle(message, on: id)
        }
    }

    // MARK: 메시지 처리

    private func handle(_ message: PeerMessage, on id: PeerConnectionID) {
        guard let connection = connections[id] else { return }

        // 자기 deviceID가 담긴 메시지는 어떤 연결에서 오든 무시한다 (hello의 자기 연결은 아래에서 정리).
        if message.deviceID == deviceID {
            if case .hello = message, connection.peer == nil { drop(id) }
            else { ignoredMessageCount += 1 }
            return
        }

        switch message {
        case .hello(let peerID, let name, let version, let route, let features):
            guard connection.peer == nil else { ignoredMessageCount += 1; return }
            guard version == PeerMessage.protocolVersion,
                  !peerID.isEmpty, !name.isEmpty, name.count <= limits.maxNameLength else {
                drop(id)
                return
            }
            register(connection, deviceID: peerID, name: name, route: connection.outboundRoute ?? route ?? .manual,
                     features: Set(features))

        case .dataChannel:
            // 데이터 채널 머리말은 연결의 첫 줄로만 의미가 있다.
            ignoredMessageCount += 1

        case .input, .session, .display, .clipboard, .fileOffer, .fileAnswer, .fileEnd:
            // hello 전이거나, hello에서 밝힌 deviceID와 다른 메시지(위장·중계)는 무시한다.
            guard let peer = connection.peer, peer.deviceID == message.deviceID else {
                ignoredMessageCount += 1
                return
            }
            onMessage?(message, peer)
        }
    }

    /// hello를 마친 연결을 피어로 등록한다. 같은 deviceID의 기존 연결이 있으면 하나만 남긴다.
    private func register(
        _ connection: Connection, deviceID peerID: String, name: String, route: PeerRoute, features: Set<String>
    ) {
        let peer = Peer(deviceID: peerID, name: name, route: route, features: features)
        guard let existing = connections.values.first(where: { $0.peer?.deviceID == peerID && $0.id != connection.id }),
              let existingPeer = existing.peer else {
            connections[connection.id]?.peer = peer
            onChange?()
            return
        }
        guard Self.keepNew(
            existingDialer: existing.isOutbound ? deviceID : peerID, existingRoute: existingPeer.route,
            newDialer: connection.isOutbound ? deviceID : peerID, newRoute: route) else {
            drop(connection.id)   // 등록 전이라 피어 목록은 그대로다.
            return
        }
        // 새 연결을 먼저 등록하고 기존 연결을 닫는다. 피어가 목록에서 잠깐 사라지지 않게 한다.
        connections[connection.id]?.peer = peer
        drop(existing.id)
    }

    /// 같은 피어에 연결이 두 개일 때 새 연결을 남길지. 양쪽이 같은 규칙으로 같은 연결을 남기도록 정한다.
    /// 1. "deviceID가 작은 쪽이 건 연결"을 남긴다.
    /// 2. 건 쪽이 같고 경로가 다르면(Bonjour와 직접 입력 주소) Bonjour 연결을 남긴다.
    ///    (새 연결을 남기면 밀려난 경로가 재연결할 때마다 서로 밀어내며 30초마다 끊긴다 — #14)
    /// 3. 건 쪽도 경로도 같으면(재연결로 낡은 연결이 남은 경우) 새 연결을 남긴다.
    static func keepNew(existingDialer: String, existingRoute: PeerRoute, newDialer: String, newRoute: PeerRoute) -> Bool {
        if newDialer != existingDialer { return newDialer < existingDialer }
        if newRoute != existingRoute { return newRoute == .bonjour }
        return true
    }

    /// 연결을 정리하고 전송 계층에도 닫도록 요청한다.
    private func drop(_ id: PeerConnectionID) {
        let hadPeer = connections.removeValue(forKey: id)?.peer != nil
        transport.close(id)
        if hadPeer { onChange?() }
    }
}

/// 데이터 채널(파일 전송용 별도 연결) 이벤트를 받는 쪽. `PeerManager`가 줄 단위 처리 없이 바이트를 그대로 넘긴다.
public protocol PeerDataChannelHandling: AnyObject {
    /// 들어온 연결의 첫 줄이 데이터 채널 머리말이다. false면 연결을 닫는다.
    func shouldAcceptDataChannel(transferID: String, from deviceID: String) -> Bool
    /// 받은 데이터 채널 바이트(머리말 제외).
    func dataChannelReceived(transferID: String, data: Data)
    /// 우리가 연 데이터 채널이 준비됐다. 머리말은 이미 보냈다.
    func dataChannelOpened(transferID: String)
    /// 우리가 연 데이터 채널에서 `sendData` 한 번 분량을 네트워크 스택에 넘겼다(보낸 순서대로).
    func dataChannelSent(transferID: String)
    /// 우리가 연 데이터 채널이 열리지 못했다.
    func dataChannelFailed(transferID: String)
    /// 데이터 채널이 닫혔다(어느 쪽이 닫았든).
    func dataChannelClosed(transferID: String)
}
