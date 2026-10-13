import AppKit
import Foundation
import VNCAutoResolutionCore

/// UI용 얇은 어댑터: 코어의 상태를 SwiftUI에 보여 주고 사용자 조작을 코어로 넘긴다.
@MainActor
final class AppModel: ObservableObject {
    private let core: AppCore
    private let detector: VNCDetecting
    private let pollInterval: Duration = .seconds(2)
    /// 클립보드 `changeCount` 확인 주기. 복사 직후 상대에서 바로 붙여 넣을 수 있게 짧게 둔다.
    private let clipboardPollInterval: Duration = .milliseconds(500)
    private var loginMessage: String?
    private let fileOffers: UserNotificationFileOffers

    @Published private(set) var launchAtLogin: Bool

    init(
        detector: VNCDetecting = SocketVNCDetector(),
        display: DisplayControlling = CoreGraphicsDisplay(),
        settings: SettingsStoring = UserDefaultsSettingsStore(),
        clock: Clock = SystemClock(),
        peerSettings: PeerSettingsStoring = UserDefaultsPeerSettings(),
        passphraseStore: PassphraseStoring = KeychainPassphraseStore(),
        inputSource: CarbonInputSource = CarbonInputSource(),
        viewerApps: WorkspaceViewerApps = WorkspaceViewerApps(),
        inputSyncSettings: InputSyncSettingsStoring = UserDefaultsInputSyncSettings(),
        screen: ScreenReading = MainScreenReader(),
        virtualDisplay: VirtualDisplayControlling = RuntimeVirtualDisplay(),
        virtualDisplaySettings: VirtualDisplaySettingsStoring = UserDefaultsVirtualDisplaySettings(),
        clipboard: ClipboardAccessing = GeneralPasteboard(),
        clipboardSettings: ClipboardSettingsStoring = UserDefaultsClipboardSettings(),
        fileOffers: UserNotificationFileOffers = UserNotificationFileOffers(),
        fileTransferSettings: FileTransferSettingsStoring = UserDefaultsFileTransferSettings()
    ) {
        self.detector = detector
        self.fileOffers = fileOffers
        // 피어 전송: Bonjour 서비스 이름은 deviceID(기기마다 유일, 사전순 비교로 연결 주체 결정).
        let transport = NetworkPeerTransport(serviceName: peerSettings.deviceID, eventQueue: .main)
        core = AppCore(
            vnc: detector, display: display, settings: settings, clock: clock,
            peerTransport: transport, peerSettings: peerSettings, passphraseStore: passphraseStore,
            deviceName: Host.current().localizedName ?? "Mac",
            inputSource: inputSource, viewerApps: viewerApps, inputSyncSettings: inputSyncSettings,
            screen: screen, virtualDisplay: virtualDisplay, virtualDisplaySettings: virtualDisplaySettings,
            clipboard: clipboard, clipboardSettings: clipboardSettings,
            fileReader: FileSystemFileReader(), fileStore: DownloadsFileStore(),
            fileOfferNotifier: fileOffers, fileTransferSettings: fileTransferSettings)
        launchAtLogin = LoginItem.isEnabled
        // 모니터·더미 플러그 연결/해제 등 디스플레이 구성 변경 시 해상도 목록을 갱신한다.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayConfigurationChanged() }
        }
        // 입력 소스 변경(TIS 분산 알림)과 뷰어 앱 실행/종료를 코어로 전달한다. (둘 다 메인 큐)
        inputSource.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.core.inputSync.localInputChanged() }
        }
        viewerApps.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.core.inputSync.viewerAppsChanged() }
        }
        if fileTransferSettings.fileReceiveEnabled { fileOffers.requestAuthorization() }
        // 알림의 수락·거절 버튼 (메인 큐)
        fileOffers.onAnswer = { [weak self] transferID, accepted in
            MainActor.assumeIsolated {
                if accepted { self?.acceptFileOffer(transferID) } else { self?.declineFileOffer(transferID) }
            }
        }
        startPeers(transport)
        Task { await pollLoop() }
        Task { await clipboardPollLoop() }
    }

    /// 전송 이벤트(메인 큐로 전달됨)를 코어 피어 매니저로 연결하고 저장된 설정으로 시작한다.
    private func startPeers(_ transport: NetworkPeerTransport) {
        core.onStateChange = { [weak self] in self?.objectWillChange.send() }
        transport.start { [weak self] event in
            MainActor.assumeIsolated { self?.core.peers.handle(event) }
        }
        core.peers.applyStoredConfig()
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let detector = self.detector
            let found = await Task.detached { detector.activeClients() }.value
            objectWillChange.send()
            core.handle(clients: found)
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func clipboardPollLoop() async {
        while !Task.isCancelled {
            core.clipboardSync.poll()
            try? await Task.sleep(for: clipboardPollInterval)
        }
    }

    // MARK: 코어 상태 (읽기 전용)

    var clients: [String] { core.resolution.clients }
    var options: [ResolutionOption] { core.resolution.options }
    var currentID: String? { core.resolution.currentID }
    var isConnected: Bool { core.resolution.isConnected }
    var hasOriginal: Bool { core.resolution.hasOriginal }
    var hasFewOptions: Bool { core.resolution.hasFewOptions }
    var lastMessage: String { loginMessage ?? core.resolution.lastMessage }

    var enabled: Bool {
        get { core.resolution.enabled }
        set { objectWillChange.send(); core.resolution.enabled = newValue }
    }

    var targetID: String {
        get { core.resolution.targetID }
        set { objectWillChange.send(); core.resolution.targetID = newValue }
    }

    // MARK: 피어 (읽기 전용 + 설정)

    var peers: [PeerManager.Peer] { core.peers.peers }
    var peerStatus: String { core.peers.statusMessage }
    var pairingPassphrase: String { core.peers.passphrase }
    var manualPeerAddress: String { core.peers.manualAddress }

    func savePairing(passphrase: String, manualAddress: String) {
        objectWillChange.send()
        core.peers.savePairing(passphrase: passphrase, manualAddress: manualAddress)
    }

    // MARK: 입력 동기화

    var inputSyncStatus: InputSyncController.Status { core.inputSync.status }
    var currentInput: InputState? { core.inputSync.currentInput }
    var inputSyncMessage: String { core.inputSync.lastMessage }

    // MARK: 클립보드 공유

    var clipboardStatus: ClipboardSyncController.Status { core.clipboardSync.lastStatus }
    var clipboardPeerSupport: ClipboardSyncController.PeerSupport { core.clipboardSync.peerSupport }

    var clipboardSyncEnabled: Bool {
        get { core.clipboardSync.enabled }
        set { objectWillChange.send(); core.clipboardSync.enabled = newValue }
    }

    // MARK: 파일 전송

    var fileTransferStatus: FileTransferController.Status { core.fileTransfer.status }
    var incomingFileOffer: IncomingFileOffer? { core.fileTransfer.incomingOffer }

    var fileReceiveEnabled: Bool {
        get { core.fileTransfer.receiveEnabled }
        set {
            objectWillChange.send()
            core.fileTransfer.receiveEnabled = newValue
            if newValue { fileOffers.requestAuthorization() }
        }
    }

    func canSendFile(to peer: PeerManager.Peer) -> Bool { core.fileTransfer.canSend(to: peer) }

    /// 파일 하나를 고르게 하고, 고르면 이 피어에게 보낸다.
    func chooseFileAndSend(to deviceID: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "보낼 파일을 고르세요 (\(FileOfferText.size(FileTransferController.maxFileBytes)) 이하)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        objectWillChange.send()
        core.fileTransfer.send(fileAt: url, to: deviceID)
    }

    func acceptFileOffer(_ transferID: String) {
        objectWillChange.send()
        core.fileTransfer.accept(transferID: transferID)
    }

    func declineFileOffer(_ transferID: String) {
        objectWillChange.send()
        core.fileTransfer.decline(transferID: transferID)
    }

    // MARK: 클라이언트 화면 (호스트가 피어에게서 받은 것)

    var clientDisplay: ClientDisplay? { core.clientDisplay }

    // MARK: 가상 디스플레이

    var virtualDisplayStatus: VirtualDisplayController.Status { core.virtualDisplay.status }
    var virtualDisplayMessage: String { core.virtualDisplay.lastMessage }
    var leftoverVirtualDisplays: Int { core.virtualDisplay.leftoverCount }

    /// 실제 화면(모니터)에서 클라이언트에 맞춘 모드. 있으면 가상 디스플레이 대신 이 모드를 쓴다.
    var clientMatchedOption: ResolutionOption? { core.clientMatchedOption }

    var fitToClient: Bool {
        get { core.virtualDisplay.fitToClient }
        set { objectWillChange.send(); core.virtualDisplay.fitToClient = newValue }
    }

    var virtualDisplayHiDPI: Bool {
        get { core.virtualDisplay.hiDPI }
        set { objectWillChange.send(); core.virtualDisplay.hiDPI = newValue }
    }

    var inputSyncEnabled: Bool {
        get { core.inputSync.enabled }
        set { objectWillChange.send(); core.inputSync.enabled = newValue }
    }

    var inputSyncOnlyDuringRemote: Bool {
        get { core.inputSync.onlyDuringRemote }
        set { objectWillChange.send(); core.inputSync.onlyDuringRemote = newValue }
    }

    // MARK: 사용자 조작

    func applyTargetNow() {
        objectWillChange.send()
        core.resolution.applyTargetNow()
    }

    func restoreOriginal() {
        objectWillChange.send()
        core.resolution.restoreOriginal()
    }

    private func displayConfigurationChanged() {
        objectWillChange.send()
        core.resolution.displayConfigurationChanged()
        core.screenConfigurationChanged()   // 클라이언트(뷰어 쪽)면 새 화면 크기를 호스트에 보낸다.
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginMessage = nil
        } catch {
            loginMessage = "로그인 항목 설정 실패: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled
    }
}
