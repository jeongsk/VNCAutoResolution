import Foundation

/// 해상도 적용·복원 로직. VNC 클라이언트 목록 변화를 받아 디스플레이 포트에 명령을 내린다.
/// 상태: 대기 / 세션 중(적용됨) / 세션 중(적용 대기·재시도). 시작 시 복원과 실패 재시도도 여기서 처리한다.
public final class ResolutionController {
    public private(set) var clients: [String] = []
    public private(set) var options: [ResolutionOption] = []
    public private(set) var currentID: String?
    public private(set) var lastMessage: String = ""
    public private(set) var lastMessageAt: Date?

    /// 순간적인 끊김에 해상도가 왔다 갔다 하지 않도록, 연속으로 이만큼 비어 있어야 해제로 본다.
    public let disconnectThreshold: Int
    private var missedPolls = 0

    /// 선택할 수 있는 해상도가 이 개수보다 적으면 더미 플러그·가상 디스플레이 안내를 띄운다.
    /// (실제 모니터는 보통 수십 개, 더미 플러그나 모니터 없는 맥미니는 한두 개뿐이다.)
    public static let fewOptionsThreshold = 4
    /// 적용 실패 후 재시도 간격(초)과, 최초 시도 이후 재시도 최대 횟수.
    public let retryInterval: TimeInterval
    public let maxRetryAttempts: Int

    private enum PendingAction { case apply, restore }
    private var pending: PendingAction?
    private var retryCount = 0
    private var nextRetryAt = Date.distantPast
    /// 앱 시작 후 첫 폴링을 이미 처리했는지. (시작 시 복원 판단용)
    private var started = false

    private let display: DisplayControlling
    private let settings: SettingsStoring
    private let clock: Clock

    public init(
        display: DisplayControlling,
        settings: SettingsStoring,
        clock: Clock,
        disconnectThreshold: Int = 2,
        retryInterval: TimeInterval = 10,
        maxRetryAttempts: Int = 6
    ) {
        self.display = display
        self.settings = settings
        self.clock = clock
        self.disconnectThreshold = disconnectThreshold
        self.retryInterval = retryInterval
        self.maxRetryAttempts = maxRetryAttempts
        refreshDisplay()
    }

    // MARK: 상태

    public var isConnected: Bool { !clients.isEmpty }
    public var hasOriginal: Bool { settings.originalResolutionID != nil }
    /// 선택 가능한 해상도가 적어 안내가 필요한지.
    public var hasFewOptions: Bool { options.count < Self.fewOptionsThreshold }
    /// 적용(또는 복원) 재시도 대기 중인지.
    public var isRetrying: Bool { pending != nil }

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
        // 시작 시 복원: 저장된 원래 해상도가 있는데 세션이 없으면 바로 되돌리고 저장값을 지운다.
        if !started {
            started = true
            if found.isEmpty && hasOriginal {
                restoreOriginal(reason: "시작 시 원래 해상도 복원")
            }
        }
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
        processRetry()
        refreshDisplay()
    }

    /// 디스플레이 구성이 바뀌었을 때(모니터·더미 플러그 연결/해제) 앱 어댑터가 호출한다. 해상도 목록을 다시 읽는다.
    public func displayConfigurationChanged() {
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
        if display.apply(id: targetID) {
            pending = nil
            report("해상도 적용됨")
        } else {
            report("해상도 변경 실패 (잠긴 화면이거나 지원하지 않는 해상도일 수 있음)")
        }
        refreshDisplay()
    }

    public func restoreOriginal(reason: String = "원래 해상도 복원") {
        guard let original = settings.originalResolutionID else { return }
        if display.apply(id: original) {
            settings.originalResolutionID = nil
            pending = nil
            report(reason)
        } else {
            // 저장값은 남겨 둬서 수동 복원·재시도·다음 실행 때 다시 시도할 수 있게 한다.
            report("복원 실패 (잠긴 화면이거나 원래 해상도를 찾지 못함)")
            if !isConnected { scheduleRetry(.restore) }
        }
        refreshDisplay()
    }

    // MARK: 내부

    private func onConnect() {
        pending = nil
        guard enabled, !targetID.isEmpty else { return }
        saveOriginalIfNeeded()
        if display.apply(id: targetID) {
            report("접속 감지 → 해상도 변경")
        } else {
            report("해상도 변경 실패 (잠긴 화면이거나 지원하지 않는 해상도일 수 있음) — \(Int(retryInterval))초 뒤 재시도")
            scheduleRetry(.apply)
        }
    }

    private func onDisconnect() {
        pending = nil
        restoreOriginal(reason: "접속 해제 → 원래 해상도 복원")
    }

    private func scheduleRetry(_ action: PendingAction) {
        pending = action
        retryCount = 0
        nextRetryAt = clock.now.addingTimeInterval(retryInterval)
    }

    /// 재시도 시각이 됐으면 해상도 목록을 다시 읽고 한 번 더 시도한다. 최대 횟수를 넘으면 멈춘다.
    private func processRetry() {
        guard let action = pending, clock.now >= nextRetryAt else { return }
        // 상황이 바뀌어 더는 의미 없는 재시도는 버린다.
        switch action {
        case .apply where !(isConnected && enabled && !targetID.isEmpty): pending = nil; return
        case .restore where isConnected || !hasOriginal: pending = nil; return
        default: break
        }

        retryCount += 1
        refreshDisplay()
        let (id, name): (String, String) = action == .apply
            ? (targetID, "해상도 변경") : (settings.originalResolutionID ?? "", "원래 해상도 복원")
        if display.apply(id: id) {
            pending = nil
            if action == .restore { settings.originalResolutionID = nil }
            report("\(name) 성공 (재시도 \(retryCount)회)")
        } else if retryCount >= maxRetryAttempts {
            pending = nil
            report("\(name) 실패 — 재시도 \(retryCount)회 후 중단")
        } else {
            nextRetryAt = clock.now.addingTimeInterval(retryInterval)
            report("\(name) 실패 — 재시도 \(retryCount)/\(maxRetryAttempts)")
        }
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
