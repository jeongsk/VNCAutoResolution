import Foundation

/// 메모리에만 저장하는 피어 설정/암호 저장소. 영속 구현을 주입하지 않은 경우의 기본값.
public final class InMemoryPeerStores: PeerSettingsStoring, PassphraseStoring {
    public let deviceID: String
    public var manualPeerAddress: String
    public var passphrase: String?

    public init(
        deviceID: String = UUID().uuidString,
        manualPeerAddress: String = "",
        passphrase: String? = nil
    ) {
        self.deviceID = deviceID
        self.manualPeerAddress = manualPeerAddress
        self.passphrase = passphrase
    }
}

/// 아무 일도 하지 않는 전송. 피어 기능을 쓰지 않는 조립(테스트 등)의 기본값.
public final class NullPeerTransport: PeerTransporting {
    public init() {}
    public func start(onEvent: @escaping @Sendable (PeerTransportEvent) -> Void) {}
    public func stop() {}
    public func updateConfig(_ config: PeerTransportConfig) {}
    public func send(_ data: Data, to id: PeerConnectionID) {}
    public func close(_ id: PeerConnectionID) {}
}
