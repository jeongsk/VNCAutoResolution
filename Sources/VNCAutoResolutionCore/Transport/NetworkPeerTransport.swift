import Foundation
import Network

/// Network.framework 기반 피어 전송 (`PeerTransporting` 구현).
///
/// 코어 라이브러리 안의 `Transport/` 폴더에 두었다: Network/CryptoKit/Security만 쓰고
/// AppKit/SwiftUI는 쓰지 않으므로 코어와 같은 타깃이어도 순수성이 깨지지 않고,
/// 별도 타깃 없이 loopback 통합 테스트가 그대로 쓸 수 있다.
///
/// - 고정 포트(기본 `PeerDefaults.port`)로 TLS-PSK 리스너를 연다. Bonjour 광고/탐색은 옵션.
/// - 연결 거는 쪽: Bonjour는 서비스 이름이 사전순으로 작은 쪽이 바로 건다. 큰 쪽도 `passiveDialDelay` 뒤에 건다.
///   (한쪽만 상대를 볼 때도 연결되게 한다. 둘 다 이어지면 코어가 작은 쪽이 건 연결만 남긴다) 직접 입력 주소는 입력한 쪽.
/// - 끊긴 연결과 `dialTimeout` 안에 준비되지 않은 연결은 백오프로 다시 건다.
/// - 데이터 채널(파일 전송용 별도 연결)은 같은 리스너·같은 TLS-PSK를 쓴다. 거는 쪽은 `connected` 대신
///   `dataChannelOpened`로 알리고 재연결하지 않는다. 받는 쪽에서는 보통 연결처럼 `connected`로 올라오고,
///   코어가 첫 줄로 데이터 채널임을 알아본다.
/// - 모든 가변 상태는 내부 직렬 큐에서만 만진다. 이벤트는 `eventQueue`로 전달한다.
public final class NetworkPeerTransport: PeerTransporting, @unchecked Sendable {
    public struct Options: Sendable {
        /// 0이면 임의 포트(테스트용). 실제 포트는 `onListening`으로 알려 준다.
        public var port: UInt16
        public var serviceType: String
        /// Bonjour 광고·탐색 사용 여부. loopback 테스트는 끈다.
        public var enableBonjour: Bool
        public var backoff: Backoff
        /// 서비스 이름이 큰 쪽이 Bonjour로 찾은 피어에 처음 연결을 걸기 전에 기다리는 시간(초).
        public var passiveDialDelay: TimeInterval
        /// 건 연결이 이 시간(초) 안에 준비되지 않으면 끊고 다시 건다.
        /// TCP 연결 시간 제한은 Bonjour 이름 풀이나 TLS 핸드셰이크에서 멈춘 경우를 못 잡는다.
        public var dialTimeout: TimeInterval

        public init(
            port: UInt16 = PeerDefaults.port,
            serviceType: String = PeerDefaults.serviceType,
            enableBonjour: Bool = true,
            backoff: Backoff = Backoff(),
            passiveDialDelay: TimeInterval = 10,
            dialTimeout: TimeInterval = 15
        ) {
            self.port = port
            self.serviceType = serviceType
            self.enableBonjour = enableBonjour
            self.backoff = backoff
            self.passiveDialDelay = passiveDialDelay
            self.dialTimeout = dialTimeout
        }
    }

    /// 리스너가 열리면 실제 포트와 함께 불린다. `start` 전에 설정한다. (eventQueue에서 호출)
    public var onListening: (@Sendable (UInt16) -> Void)?

    private final class Live: @unchecked Sendable {
        let id: PeerConnectionID
        let connection: NWConnection
        let isOutbound: Bool
        let targetKey: String?
        /// 우리가 연 데이터 채널이면 그 전송 ID.
        let dataTransferID: String?
        var announced = false
        var closedByUs = false
        init(id: PeerConnectionID, connection: NWConnection, isOutbound: Bool, targetKey: String?,
             dataTransferID: String? = nil) {
            self.id = id
            self.connection = connection
            self.isOutbound = isOutbound
            self.targetKey = targetKey
            self.dataTransferID = dataTransferID
        }
    }

    private final class Target: @unchecked Sendable {
        let key: String
        let route: PeerRoute
        let endpoint: NWEndpoint
        var attempt = 0
        var liveID: PeerConnectionID?
        var retry: DispatchWorkItem?
        init(key: String, route: PeerRoute, endpoint: NWEndpoint) {
            self.key = key
            self.route = route
            self.endpoint = endpoint
        }
    }

    private let serviceName: String
    private let options: Options
    private let eventQueue: DispatchQueue
    private let queue = DispatchQueue(label: "VNCAutoResolution.peer-transport")

    // 아래는 모두 `queue` 에서만 접근한다.
    private var handler: (@Sendable (PeerTransportEvent) -> Void)?
    private var running = false
    private var config: PeerTransportConfig?
    private var activePassphrase: String?
    private var activeManualAddress: String?
    private var generation = 0
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [PeerConnectionID: Live] = [:]
    private var targets: [String: Target] = [:]
    private var nextID: PeerConnectionID = 1
    private var listenerAttempt = 0

    /// - Parameters:
    ///   - serviceName: Bonjour 서비스 이름. 기기마다 유일해야 한다(deviceID 사용). 사전순 비교로 연결 주체를 정한다.
    ///   - eventQueue: 이벤트를 전달할 직렬 큐.
    public init(serviceName: String, eventQueue: DispatchQueue, options: Options = Options()) {
        self.serviceName = serviceName
        self.eventQueue = eventQueue
        self.options = options
    }

    // MARK: PeerTransporting

    public func start(onEvent: @escaping @Sendable (PeerTransportEvent) -> Void) {
        queue.async {
            self.handler = onEvent
            self.running = true
            self.reconcile()
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.tearDownNetwork()
            self.activePassphrase = nil
            self.activeManualAddress = nil
        }
    }

    public func updateConfig(_ config: PeerTransportConfig) {
        queue.async {
            self.config = config
            self.reconcile()
        }
    }

    public func send(_ data: Data, to id: PeerConnectionID) {
        queue.async {
            guard let live = self.connections[id], live.announced else { return }
            let isDataChannel = live.dataTransferID != nil
            live.connection.send(content: data, completion: .contentProcessed { error in
                guard error != nil else {
                    if isDataChannel { self.emit(.dataSent(id)) }
                    return
                }
                self.queue.async { self.finish(id) }
            })
        }
    }

    public func close(_ id: PeerConnectionID) {
        queue.async {
            self.connections[id]?.closedByUs = true
            self.finish(id)
        }
    }

    public func openDataChannel(alongside peer: PeerConnectionID, port: UInt16?, transferID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let passphrase = self.activePassphrase, !passphrase.isEmpty,
                  let live = self.connections[peer], live.announced,
                  let endpoint = self.dataChannelEndpoint(for: live, port: port) else {
                self.emit(.dataChannelFailed(transferID: transferID))
                return
            }
            // 데이터 채널은 제어 연결(한/영 동기화·세션 신호)보다 낮은 우선순위로 보낸다.
            let connection = NWConnection(
                to: endpoint, using: self.parameters(passphrase: passphrase, serviceClass: .background))
            let channel = self.adopt(connection, isOutbound: true, targetKey: nil, dataTransferID: transferID)
            self.queue.asyncAfter(deadline: .now() + self.options.dialTimeout) { [weak self, weak channel] in
                guard let self, let channel, self.connections[channel.id] === channel, !channel.announced else { return }
                self.finish(channel.id)
            }
        }
    }

    /// 데이터 채널을 걸 주소. 우리가 건 피어 연결이면 그 주소(직접 입력·Bonjour)를 그대로 쓴다.
    /// 들어온 연결이면 상대 호스트에 상대가 알려 준 리스너 포트를 붙인다.
    /// (상대가 NAT 뒤에서 걸어 온 경우에는 닿지 않을 수 있다. Tailscale·같은 네트워크는 문제없다)
    private func dataChannelEndpoint(for live: Live, port: UInt16?) -> NWEndpoint? {
        if let key = live.targetKey, let target = targets[key] { return target.endpoint }
        let remote = live.connection.currentPath?.remoteEndpoint ?? live.connection.endpoint
        guard case .hostPort(let host, _) = remote, let port, let listenPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }
        return .hostPort(host: host, port: listenPort)
    }

    // MARK: 설정 반영

    /// 현재 설정과 실행 상태에 맞게 네트워크를 맞춘다. 암호가 바뀌면 전부 새로 연다.
    private func reconcile() {
        guard running, let config else { return }
        if config.passphrase != activePassphrase {
            tearDownNetwork()
            activePassphrase = config.passphrase
            activeManualAddress = nil
            if !config.passphrase.isEmpty { startNetwork(passphrase: config.passphrase) }
        }
        guard !config.passphrase.isEmpty else { return }
        let manual = config.manualAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if manual != (activeManualAddress ?? "") {
            activeManualAddress = manual
            applyManualTarget(manual)
        }
    }

    private func startNetwork(passphrase: String) {
        generation += 1
        listenerAttempt = 0
        startListener(passphrase: passphrase, generation: generation)
        if options.enableBonjour { startBrowser() }
    }

    private func tearDownNetwork() {
        generation += 1
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for target in targets.values { target.retry?.cancel() }
        targets.removeAll()
        for live in Array(connections.values) {
            live.closedByUs = true
            finish(live.id)
        }
    }

    private func parameters(passphrase: String,
                            serviceClass: NWParameters.ServiceClass = .responsiveData) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: PairingKey.tlsOptions(passphrase: passphrase), tcp: tcp)
        params.serviceClass = serviceClass
        params.allowLocalEndpointReuse = true
        return params
    }

    // MARK: 리스너

    private func startListener(passphrase: String, generation: Int) {
        do {
            let port: NWEndpoint.Port = options.port == 0 ? .any : NWEndpoint.Port(rawValue: options.port)!
            let l = try NWListener(using: parameters(passphrase: passphrase), on: port)
            if options.enableBonjour {
                l.service = NWListener.Service(name: serviceName, type: options.serviceType)
            }
            l.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == generation else { connection.cancel(); return }
                self.adopt(connection, isOutbound: false, targetKey: nil)
            }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready:
                    // 실패했다가 재시도로 열렸다면 남아 있는 실패 메시지를 지운다.
                    if self.listenerAttempt > 0 { self.emit(.status("")) }
                    self.listenerAttempt = 0
                    if let p = l?.port?.rawValue {
                        self.emit(.listening(p))
                        self.eventQueue.async { self.onListening?(p) }
                    }
                case .failed(let error):
                    l?.cancel()
                    self.emit(.status("리스너 시작 실패: \(error.localizedDescription)"))
                    let delay = self.options.backoff.delay(attempt: self.listenerAttempt)
                    self.listenerAttempt += 1
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        guard self.generation == generation, self.running else { return }
                        self.startListener(passphrase: passphrase, generation: generation)
                    }
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            emit(.status("리스너 시작 실패: \(error.localizedDescription)"))
        }
    }

    // MARK: Bonjour 탐색

    private func startBrowser() {
        let b = NWBrowser(for: .bonjour(type: options.serviceType, domain: nil), using: NWParameters())
        let gen = generation
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.generation == gen else { return }
            self.updateBonjourTargets(results)
        }
        b.start(queue: queue)
        browser = b
    }

    /// 탐색 결과의 피어에 연결을 건다. 내 서비스 이름이 작으면 바로, 크면 `passiveDialDelay` 뒤에 건다.
    private func updateBonjourTargets(_ results: Set<NWBrowser.Result>) {
        var wanted: [String: (endpoint: NWEndpoint, passive: Bool)] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, name != serviceName else { continue }
            wanted["bonjour-\(name)"] = (result.endpoint, serviceName > name)
        }
        for (key, target) in targets where target.route == .bonjour && wanted[key] == nil {
            target.retry?.cancel()
            targets[key] = nil
        }
        for (key, found) in wanted where targets[key] == nil {
            let target = Target(key: key, route: .bonjour, endpoint: found.endpoint)
            targets[key] = target
            if found.passive {
                let work = DispatchWorkItem { [weak self, weak target] in
                    guard let self, let target, self.targets[target.key] === target else { return }
                    self.dial(target)
                }
                target.retry = work
                queue.asyncAfter(deadline: .now() + options.passiveDialDelay, execute: work)
            } else {
                dial(target)
            }
        }
    }

    // MARK: 직접 입력 주소

    private func applyManualTarget(_ text: String) {
        if let old = targets["manual"] {
            old.retry?.cancel()
            targets["manual"] = nil
            if let id = old.liveID {
                connections[id]?.closedByUs = true
                finish(id)
            }
        }
        guard !text.isEmpty else { return }
        guard let address = PeerAddress.parse(text), let port = NWEndpoint.Port(rawValue: address.port) else {
            emit(.status("직접 연결 주소가 올바르지 않습니다: \(text)"))
            return
        }
        let target = Target(
            key: "manual", route: .manual,
            endpoint: .hostPort(host: NWEndpoint.Host(address.host), port: port))
        targets["manual"] = target
        dial(target)
    }

    // MARK: 연결

    private func dial(_ target: Target) {
        guard target.liveID == nil, let passphrase = activePassphrase, !passphrase.isEmpty else { return }
        let connection = NWConnection(to: target.endpoint, using: parameters(passphrase: passphrase))
        let live = adopt(connection, isOutbound: true, targetKey: target.key)
        target.liveID = live.id
        queue.asyncAfter(deadline: .now() + options.dialTimeout) { [weak self, weak live] in
            guard let self, let live, self.connections[live.id] === live, !live.announced else { return }
            self.finish(live.id)
        }
    }

    @discardableResult
    private func adopt(_ connection: NWConnection, isOutbound: Bool, targetKey: String?,
                       dataTransferID: String? = nil) -> Live {
        let id = nextID
        nextID += 1
        let live = Live(id: id, connection: connection, isOutbound: isOutbound, targetKey: targetKey,
                        dataTransferID: dataTransferID)
        connections[id] = live
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !live.announced, self.connections[id] === live else { return }
                live.announced = true
                if let transferID = dataTransferID {
                    self.emit(.dataChannelOpened(id, transferID: transferID))
                } else {
                    let route = targetKey.flatMap { self.targets[$0]?.route }
                    if let key = targetKey { self.targets[key]?.attempt = 0 }
                    self.emit(.connected(id, route: route, isOutbound: isOutbound))
                }
                self.receiveLoop(live)
            case .failed, .waiting, .cancelled:
                // 핸드셰이크 실패(암호 불일치 포함)는 .failed/.waiting 으로 온다.
                self.finish(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        return live
    }

    /// 받은 조각을 코어가 처리한 뒤에(이벤트 큐에서 핸들러가 돌고 나서) 다음 조각을 받는다.
    /// 코어가 디스크 쓰기 등으로 네트워크보다 느려도 받은 바이트가 이벤트 큐에 쌓이지 않고 TCP 흐름 제어로 넘어간다.
    private func receiveLoop(_ live: Live) {
        live.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, self.connections[live.id] === live else { return }
            let next: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard self.connections[live.id] === live else { return }
                    if error != nil || isComplete {
                        self.finish(live.id)
                    } else {
                        self.receiveLoop(live)
                    }
                }
            }
            if let data, !data.isEmpty {
                self.emit(.received(live.id, data), then: next)
            } else {
                next()
            }
        }
    }

    /// 연결 정리(여러 번 불려도 안전). 알린 연결이면 disconnected를 올리고, 우리가 건 연결이면 백오프로 재시도한다.
    private func finish(_ id: PeerConnectionID) {
        guard let live = connections.removeValue(forKey: id) else { return }
        live.connection.stateUpdateHandler = nil
        live.connection.cancel()
        if live.announced {
            emit(.disconnected(id))
        } else if let transferID = live.dataTransferID {
            emit(.dataChannelFailed(transferID: transferID))
        }
        guard let key = live.targetKey, let target = targets[key], target.liveID == id else { return }
        target.liveID = nil
        // 우리가 닫은 연결(중복·자기 자신 정리)은 상한 간격으로 천천히 다시 건다.
        let attempt = live.closedByUs ? Int.max : target.attempt
        let delay = options.backoff.delay(attempt: attempt)
        target.attempt += 1
        let work = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target, self.targets[target.key] === target else { return }
            self.dial(target)
        }
        target.retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 이벤트를 전달한다. `then`은 핸들러가 돈 뒤 이벤트 큐에서 부른다.
    private func emit(_ event: PeerTransportEvent, then done: (@Sendable () -> Void)? = nil) {
        guard let handler else { done?(); return }
        eventQueue.async {
            handler(event)
            done?()
        }
    }
}
