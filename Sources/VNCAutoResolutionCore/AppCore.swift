/// 앱 코어 최상위 조립체. 포트를 주입받아 하위 컴포넌트를 구성한다.
/// 새 기능(피어, 입력 동기화 등)은 별도 컴포넌트를 만들어 여기서 조립한다.
public final class AppCore {
    public let resolution: ResolutionController
    public let peers: PeerManager

    private let vnc: VNCDetecting

    public init(
        vnc: VNCDetecting,
        display: DisplayControlling,
        settings: SettingsStoring,
        clock: Clock,
        peerTransport: PeerTransporting = NullPeerTransport(),
        peerSettings: (PeerSettingsStoring & PassphraseStoring) = InMemoryPeerStores(),
        deviceName: String = "Mac"
    ) {
        self.vnc = vnc
        self.resolution = ResolutionController(display: display, settings: settings, clock: clock)
        self.peers = PeerManager(
            deviceName: deviceName, transport: peerTransport,
            settings: peerSettings, secrets: peerSettings, clock: clock)
    }

    /// 폴링 한 번: VNC 포트를 읽어 `handle(clients:)`로 넘긴다. (블로킹 호출 — 테스트에서 직접 호출)
    public func tick() {
        handle(clients: vnc.activeClients())
    }

    /// 이미 읽어 온 VNC 클라이언트 목록을 처리한다. 앱은 블로킹 감지를 백그라운드에서 하고 이 메서드를 호출한다.
    public func handle(clients: [String]) {
        resolution.handle(clients: clients)
    }
}
