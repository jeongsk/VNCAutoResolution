/// 앱 코어 최상위 조립체. 포트를 주입받아 하위 컴포넌트를 구성한다.
/// 새 기능(피어, 입력 동기화 등)은 별도 컴포넌트를 만들어 여기서 조립한다.
public final class AppCore {
    public let resolution: ResolutionController
    public let peers: PeerManager
    public let inputSync: InputSyncController
    /// 클라이언트 화면 정보 송수신. 가상 디스플레이(#9)는 `clientDisplay`를 읽는다.
    public let clientDisplayController: ClientDisplayController

    /// 클라이언트 화면 크기의 가상 디스플레이. 있는 동안 `resolution`은 멈춘다.
    public let virtualDisplay: VirtualDisplayController

    /// 피어 목록·입력 동기화 상태가 바뀔 때마다 불린다. (UI 갱신용. `peers.onChange`는 코어가 쓴다.)
    public var onStateChange: (() -> Void)?

    /// 호스트가 알고 있는 클라이언트 화면(세션이 활성인 피어가 보낸 가장 최근 `display`). 없으면 nil.
    public var clientDisplay: ClientDisplay? { clientDisplayController.clientDisplay }
    /// `clientDisplay`가 바뀔 때마다 불린다. (가상 디스플레이 컨트롤러는 코어 안에서 따로 연결돼 있고, 이 클로저는 앱용이다.)
    public var onClientDisplayChange: (() -> Void)?

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
        inputSyncSettings: InputSyncSettingsStoring? = nil,
        screen: ScreenReading? = nil,
        virtualDisplay: VirtualDisplayControlling? = nil,
        virtualDisplaySettings: VirtualDisplaySettingsStoring? = nil
    ) {
        self.vnc = vnc
        self.resolution = ResolutionController(display: display, settings: settings, clock: clock)
        self.virtualDisplay = VirtualDisplayController(
            port: virtualDisplay ?? NullVirtualDisplay(),
            settings: virtualDisplaySettings ?? InMemoryVirtualDisplaySettings(), clock: clock)
        let fallback = InMemoryPeerStores()
        self.peers = PeerManager(
            deviceName: deviceName, transport: peerTransport,
            settings: peerSettings ?? fallback, secrets: passphraseStore ?? fallback, clock: clock)
        self.inputSync = InputSyncController(
            input: inputSource ?? NullInputSource(), viewers: viewerApps ?? NullViewerAppDetector(),
            settings: inputSyncSettings ?? InMemoryInputSyncSettings(), peers: peers, clock: clock)
        self.clientDisplayController = ClientDisplayController(
            screen: screen ?? NullScreenReader(), peers: peers, inputSync: inputSync)

        // 가상 디스플레이와 해상도 컨트롤러는 서로 배타적이다. 세션 판단은 해상도 컨트롤러의 것(디바운스 포함)을 같이 쓴다.
        // 가상 디스플레이가 있는 동안 해상도 컨트롤러는 멈추고, 새 세션이 시작되면 가상 디스플레이가 먼저 자리를 잡는다.
        let resolution = self.resolution
        let virtualDisplay = self.virtualDisplay
        virtualDisplay.session = { [unowned resolution] in resolution.isConnected }
        virtualDisplay.clientDisplay = { [weak self] in self?.clientDisplay }
        virtualDisplay.willCreate = { [unowned resolution] in resolution.yieldToVirtualDisplay() }
        virtualDisplay.didRemove = { [unowned resolution] in resolution.virtualDisplayRemoved() }
        virtualDisplay.onChange = { [weak self] in self?.onStateChange?() }
        resolution.isSuspended = { [unowned virtualDisplay] in virtualDisplay.isActive }
        resolution.onSessionStart = { [unowned virtualDisplay] in virtualDisplay.sync() }
        // 실제 화면에 클라이언트에 맞는 모드가 있으면 가상 디스플레이 대신 그 모드를 쓴다.
        resolution.clientMatchID = { [weak self] in self?.clientMatchedOption?.id }
        virtualDisplay.physicalDisplayFits = { [weak self] in self?.clientMatchedOption != nil }
        virtualDisplay.settingsChanged = { [unowned resolution] in resolution.sessionTargetChanged() }

        // 피어 메시지·목록 변화를 입력 동기화에 연결한다. 앱은 `onStateChange`로 UI 갱신만 받는다.
        let sync = inputSync
        let display = clientDisplayController
        peers.onMessage = { message, peer in
            if case .display = message { display.handle(message, from: peer) } else { sync.handle(message, from: peer) }
        }
        peers.onChange = { [weak self] in
            self?.inputSync.peersChanged()
            self?.clientDisplayController.refresh()   // 연결이 끊긴 피어의 화면 정보를 비운다.
            self?.onStateChange?()
        }
        inputSync.onChange = { [weak self] in
            self?.clientDisplayController.refresh()   // 세션 신호 만료·종료 시 화면 정보를 비운다.
            self?.onStateChange?()
        }
        // 클라이언트(뷰어 쪽)는 세션 시작·새 피어 연결 때 화면 크기를 보낸다.
        inputSync.onLocalSessionStarted = { display.sendIfViewer() }
        inputSync.onPeerJoined = { display.sendIfViewer() }
        clientDisplayController.onChange = { [weak self] in
            self?.virtualDisplay.sync()   // 크기가 바뀌면 모드 변경, 사라지면 제거.
            self?.resolution.sessionTargetChanged()   // 실제 화면 모드로 맞추는 경우.
            self?.onClientDisplayChange?()
            self?.onStateChange?()
        }
    }

    /// 실제 화면에서 클라이언트 화면에 맞춘 모드. 맞추기가 꺼졌거나 화면 정보가 없거나 맞는 모드가 없으면 nil.
    public var clientMatchedOption: ResolutionOption? {
        guard virtualDisplay.fitToClient, let client = clientDisplay else { return nil }
        return ClientModeMatcher.bestOption(for: client, hiDPI: virtualDisplay.hiDPI, in: resolution.options)
    }

    /// 화면 구성(해상도 설정, 모니터 연결·해제)이 바뀌었을 때 앱이 부른다. 클라이언트면 새 화면 크기를 보낸다.
    public func screenConfigurationChanged() {
        clientDisplayController.sendIfViewer()
    }

    /// 폴링 한 번: VNC 포트를 읽어 `handle(clients:)`로 넘긴다. (블로킹 호출 — 테스트에서 직접 호출)
    public func tick() {
        handle(clients: vnc.activeClients())
    }

    /// 이미 읽어 온 VNC 클라이언트 목록을 처리한다. 앱은 블로킹 감지를 백그라운드에서 하고 이 메서드를 호출한다.
    public func handle(clients: [String]) {
        resolution.handle(clients: clients)
        virtualDisplay.sync()
        inputSync.setLocalVNC(active: resolution.isConnected)
        inputSync.tick()
    }
}
