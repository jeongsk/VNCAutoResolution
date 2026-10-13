import Foundation
import VNCAutoResolutionCore

/// 테스트용 피어 전송. 보낸 바이트와 닫은 연결을 기록한다.
final class FakePeerTransport: PeerTransporting {
    private(set) var sent: [(id: PeerConnectionID, data: Data)] = []
    private(set) var closed: [PeerConnectionID] = []
    private(set) var configs: [PeerTransportConfig] = []

    func start(onEvent: @escaping @Sendable (PeerTransportEvent) -> Void) {}
    func stop() {}
    func updateConfig(_ config: PeerTransportConfig) { configs.append(config) }
    func send(_ data: Data, to id: PeerConnectionID) { sent.append((id, data)) }
    func close(_ id: PeerConnectionID) { closed.append(id) }
    func clearSent() { sent.removeAll() }

    /// 연결 `id`로 보낸 메시지들.
    func messages(to id: PeerConnectionID) -> [PeerMessage] {
        sent.filter { $0.id == id }.flatMap { entry -> [PeerMessage] in
            var framer = MessageFramer(maxLineLength: PeerManager.Limits().maxMessageBytes)
            return framer.append(entry.data).compactMap(PeerCodec.decode)
        }
    }
}
