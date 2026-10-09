import Foundation

/// 전송 계층이 연결마다 붙이는 식별자. 연결이 끊기면 다시 쓰이지 않는다.
public typealias PeerConnectionID = UInt64

/// 피어에 연결한 경로. 메뉴에 "자동 탐색"/"직접 입력"으로 표시한다.
public enum PeerRoute: String, Codable, Sendable {
    case bonjour
    case manual
}

/// 전송 계층이 코어로 올려 보내는 이벤트.
public enum PeerTransportEvent: Sendable {
    /// TLS-PSK 핸드셰이크까지 끝나 바이트를 주고받을 수 있게 됐다.
    /// `route`는 우리가 건 연결일 때만 안다(들어온 연결은 nil — 상대가 hello로 알려 준다).
    case connected(PeerConnectionID, route: PeerRoute?, isOutbound: Bool)
    /// 연결에서 받은 원시 바이트. 메시지 경계(줄바꿈)와 무관하게 잘리거나 합쳐져 올 수 있다.
    case received(PeerConnectionID, Data)
    case disconnected(PeerConnectionID)
    /// 사용자에게 보여 줄 전송 계층 상태/오류 (예: 리스너 시작 실패).
    case status(String)
}

/// 전송 계층 설정. 암호가 비어 있으면 전송 계층은 아무것도 열지 않는다.
public struct PeerTransportConfig: Equatable, Sendable {
    public var passphrase: String
    /// 직접 연결할 피어 주소("host" 또는 "host:port"). nil/빈 값이면 직접 연결 없음.
    public var manualAddress: String?

    public init(passphrase: String, manualAddress: String? = nil) {
        self.passphrase = passphrase
        self.manualAddress = manualAddress
    }
}

/// 피어 전송 포트 (테스트 seam ②). 바이트 파이프만 제공한다 — 메시지 분리·검증은 코어가 한다.
/// 이벤트는 구현체가 정한 큐에서 순서대로 전달된다. 나머지 메서드는 어느 스레드에서 불러도 된다.
public protocol PeerTransporting: AnyObject {
    /// 이벤트 수신자를 등록하고 동작을 시작한다. 설정은 `updateConfig`로 따로 넘긴다.
    func start(onEvent: @escaping @Sendable (PeerTransportEvent) -> Void)
    func stop()
    /// 설정을 바꾼다. 암호가 바뀌면 기존 연결을 모두 끊고 다시 시작한다.
    func updateConfig(_ config: PeerTransportConfig)
    /// 연결에 바이트를 보낸다. (메시지 하나 = `PeerCodec.encode` 결과 한 덩어리)
    func send(_ data: Data, to id: PeerConnectionID)
    /// 연결을 닫는다. 이후 `disconnected`가 올 수 있다.
    func close(_ id: PeerConnectionID)
}
