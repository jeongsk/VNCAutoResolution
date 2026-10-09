/// 앱 코어 최상위 조립체. 포트를 주입받아 하위 컴포넌트를 구성한다.
/// 새 기능(피어, 입력 동기화 등)은 별도 컴포넌트를 만들어 여기서 조립한다.
public final class AppCore {
    public let resolution: ResolutionController
    public let peers: PeerManager
    public let inputSync: InputSyncController

    /// 피어 목록·입력 동기화 상태가 바뀔 때마다 불린다. (UI 갱신용. `peers.onChange`는 코어가 쓴다.)
    public var onStateChange: (() -> Void)?

    private let vnc: VNCDetecting

    public init(
        vnc: VNCDetecting,
        display: DisplayControlling,
        settings: SettingsStoring,
        clock: Clock,
        peerTransport: PeerTransporting = NullPeerTransport(),
        peerSettings: PeerSettingsStoring? = nil,
        passphraseStore: PassphraseStoring? = nil,
        deviceName: String = "Mac",
        inputSource: InputSourcing? = nil,
        viewerApps: ViewerAppDetecting? = nil,
        inputSyncSettings: InputSyncSettingsStoring? = nil
    ) {
        self.vnc = vnc
        self.resolution = ResolutionController(display: display, settings: settings, clock: clock)
        let fallback = InMemoryPeerStores()
        self.peers = PeerManager(
            deviceName: deviceName, transport: peerTransport,
            settings: peerSettings ?? fallback, secrets: passphraseStore ?? fallback, clock: clock)
        self.inputSync = InputSyncController(
            input: inputSource ?? NullInputSource(), viewers: viewerApps ?? NullViewerAppDetector(),
            settings: inputSyncSettings ?? InMemoryInputSyncSettings(), peers: peers, clock: clock)

        // 피어 메시지·목록 변화를 입력 동기화에 연결한다. 앱은 `onStateChange`로 UI 갱신만 받는다.
        let sync = inputSync
        peers.onMessage = { message, peer in sync.handle(message, from: peer) }
        peers.onChange = { [weak self] in
            self?.inputSync.peersChanged()
            self?.onStateChange?()
        }
        inputSync.onChange = { [weak self] in self?.onStateChange?() }
    }

    /// 폴링 한 번: VNC 포트를 읽어 `handle(clients:)`로 넘긴다. (블로킹 호출 — 테스트에서 직접 호출)
    public func tick() {
        handle(clients: vnc.activeClients())
    }

    /// 이미 읽어 온 VNC 클라이언트 목록을 처리한다. 앱은 블로킹 감지를 백그라운드에서 하고 이 메서드를 호출한다.
    public func handle(clients: [String]) {
        resolution.handle(clients: clients)
        inputSync.setLocalVNC(active: resolution.isConnected)
        inputSync.tick()
    }
}
