import Foundation

/// 해상도 적용·복원 로직. VNC 클라이언트 목록 변화를 받아 디스플레이 포트에 명령을 내린다.
/// (#3 에서 상태 머신·재시도·시작 시 복원을 이 컴포넌트에 확장한다.)
public final class ResolutionController {
    public private(set) var clients: [String] = []
    public private(set) var options: [ResolutionOption] = []
    public private(set) var currentID: String?
    public private(set) var lastMessage: String = ""
    public private(set) var lastMessageAt: Date?

    /// 순간적인 끊김에 해상도가 왔다 갔다 하지 않도록, 연속으로 이만큼 비어 있어야 해제로 본다.
    public let disconnectThreshold: Int
    private var missedPolls = 0

    private let display: DisplayControlling
    private let settings: SettingsStoring
    private let clock: Clock

    public init(
        display: DisplayControlling,
        settings: SettingsStoring,
        clock: Clock,
        disconnectThreshold: Int = 2
    ) {
        self.display = display
        self.settings = settings
        self.clock = clock
        self.disconnectThreshold = disconnectThreshold
        refreshDisplay()
    }

    // MARK: 상태

    public var isConnected: Bool { !clients.isEmpty }
    public var hasOriginal: Bool { settings.originalResolutionID != nil }

    public var enabled: Bool {
        get { settings.autoChangeEnabled }
        set { settings.autoChangeEnabled = newValue }
    }

    public var targetID: String {
        get { settings.targetResolutionID }
        set { settings.targetResolutionID = newValue }
    }

    // MARK: 이벤트

    /// 폴링 결과(현재 VNC 클라이언트 목록)를 처리한다.
    public func handle(clients found: [String]) {
        if !found.isEmpty {
            missedPolls = 0
            let wasConnected = isConnected
            clients = found
            if !wasConnected { onConnect() }
        } else if isConnected {
            missedPolls += 1
            if missedPolls >= disconnectThreshold {
                clients = []
                onDisconnect()
            }
        }
        refreshDisplay()
    }

    public func refreshDisplay() {
        let newOptions = display.availableOptions()
        if newOptions != options { options = newOptions }
        let id = display.currentOption()?.id
        if id != currentID { currentID = id }
    }

    // MARK: 사용자 조작

    public func applyTargetNow() {
        guard !targetID.isEmpty else { return }
        saveOriginalIfNeeded()
        report(display.apply(id: targetID) ? "해상도 적용됨" : "해상도 변경 실패")
        refreshDisplay()
    }

    public func restoreOriginal(reason: String = "원래 해상도 복원") {
        guard let original = settings.originalResolutionID else { return }
        let ok = display.apply(id: original)
        report(ok ? reason : "복원 실패 (원래 해상도를 찾지 못함)")
        settings.originalResolutionID = nil
        refreshDisplay()
    }

    // MARK: 내부

    private func onConnect() {
        guard enabled, !targetID.isEmpty else { return }
        saveOriginalIfNeeded()
        report(display.apply(id: targetID) ? "접속 감지 → 해상도 변경" : "해상도 변경 실패")
    }

    private func onDisconnect() {
        restoreOriginal(reason: "접속 해제 → 원래 해상도 복원")
    }

    private func saveOriginalIfNeeded() {
        if settings.originalResolutionID == nil {
            settings.originalResolutionID = display.currentOption()?.id
        }
    }

    private func report(_ message: String) {
        lastMessage = message
        lastMessageAt = clock.now
    }
}
