import Foundation

/// 클라이언트 화면 크기의 가상 디스플레이를 만들고 없애는 컨트롤러.
///
/// 생성 조건(모두 만족): 기능 켜짐 + 로컬 VNC 세션 + 클라이언트 화면 정보 + 포트 사용 가능 + 고성능 가상 디스플레이 없음.
/// - 세션 판단은 `ResolutionController`의 것(연속 2회 미감지 디바운스 적용)을 `session` 클로저로 받아 그대로 쓴다.
/// - 클라이언트 화면 정보가 바뀌면 모드를 바꾼다. 세션이 끝나거나 기능을 끄거나 포트를 쓸 수 없게 되면 제거한다.
/// - 만든 뒤 클라이언트 화면 정보만 사라지면(세션 신호 만료·피어 연결 끊김) 마지막 모드를 유지하고, 세션이 끝날 때 제거한다.
/// - 고성능 가상 디스플레이 검사는 "만들 때"만 한다. 이미 만든 뒤에 고성능 세션이 시작돼도 끼어들어 없애지 않는다.
/// - 만들거나 모드를 바꾸는 데 실패하면 `retryInterval`초 간격으로 최대 `maxAttempts`번까지 시도한다.
///   (조건이 바뀌면 — 모드·설정·세션 — 시도 횟수를 새로 센다.)
///
/// 스레드: 메인 스레드 전용.
public final class VirtualDisplayController {
    public enum Status: Equatable {
        /// 이 OS에서 만들 수 없다.
        case unavailable
        /// 가상 디스플레이가 없다. (기능 꺼짐, 세션 없음, 화면 정보 없음, 고성능 가상 디스플레이 있음 등)
        case standby
        /// 가상 디스플레이가 있다. 포인트 크기.
        case active(width: Int, height: Int)
    }

    public private(set) var lastMessage: String = ""

    /// 로컬 VNC 세션이 있는지. (`ResolutionController.isConnected`)
    var session: () -> Bool = { false }
    /// 클라이언트 화면 정보. (`AppCore.clientDisplay`)
    var clientDisplay: () -> ClientDisplay? = { nil }
    /// 가상 디스플레이를 만들기 직전. (해상도 컨트롤러가 적용해 둔 목표 해상도를 되돌린다)
    var willCreate: (() -> Void)?
    /// 가상 디스플레이가 사라진 직후. (해상도 컨트롤러가 다시 일할 수 있게 한다)
    var didRemove: (() -> Void)?
    /// 상태가 바뀔 때 불린다. (UI 갱신용)
    public var onChange: (() -> Void)?
    /// 실제 화면에 클라이언트에 맞는 모드가 있는지. 있으면 새로 만들지 않는다. (해상도 컨트롤러가 그 모드로 바꾼다)
    var physicalDisplayFits: () -> Bool = { false }
    /// 맞추기·HiDPI 설정이 바뀐 직후. (해상도 컨트롤러가 맞출 모드를 다시 고른다)
    var settingsChanged: (() -> Void)?

    public let retryInterval: TimeInterval
    public let maxAttempts: Int

    private let port: VirtualDisplayControlling
    private let settings: VirtualDisplaySettingsStoring
    private let clock: Clock

    private var currentMode: VirtualDisplayMode?
    private var failedMode: VirtualDisplayMode?
    private var attempts = 0
    private var nextAttemptAt = Date.distantPast

    public init(
        port: VirtualDisplayControlling, settings: VirtualDisplaySettingsStoring, clock: Clock,
        retryInterval: TimeInterval = 10, maxAttempts: Int = 3
    ) {
        self.port = port
        self.settings = settings
        self.clock = clock
        self.retryInterval = retryInterval
        self.maxAttempts = maxAttempts
    }

    // MARK: 상태·설정

    /// 가상 디스플레이가 있는 동안 true. 이 동안 `ResolutionController`는 아무것도 하지 않는다.
    public var isActive: Bool { currentMode != nil && port.isActive }

    public var status: Status {
        guard port.isAvailable else { return .unavailable }
        guard isActive, let mode = currentMode else { return .standby }
        let size = port.activeSize ?? mode.pointSize
        return .active(width: size.width, height: size.height)
    }

    /// 정리되지 않고 남은 가상 디스플레이 수. (UI 경고용)
    public var leftoverCount: Int { port.isAvailable ? port.leftoverCount : 0 }

    public var fitToClient: Bool {
        get { settings.fitToClientEnabled }
        set { settings.fitToClientEnabled = newValue; resetAttempts(); sync(); settingsChanged?() }
    }

    public var hiDPI: Bool {
        get { settings.virtualDisplayHiDPI }
        set { settings.virtualDisplayHiDPI = newValue; resetAttempts(); sync(); settingsChanged?() }
    }

    // MARK: 동기화

    /// 지금 상태를 조건에 맞춘다. 폴링마다, 클라이언트 화면 정보가 바뀔 때, 세션이 시작될 때, 설정이 바뀔 때 부른다.
    public func sync() {
        // 포트가 스스로 사라진 경우(예: 시스템이 제거)에도 상태를 맞춘다.
        if currentMode != nil, !port.isActive {
            currentMode = nil
            didRemove?()
            onChange?()
        }

        guard let desired = desiredMode() else {
            if currentMode != nil { removeNow(reason: removalReason()) }
            resetAttempts()
            return
        }
        if let mode = currentMode {
            if mode != desired { changeMode(to: desired) }
        } else {
            create(desired)
        }
    }

    /// 지금 조건에서 만들어야 하는 모드. 만들면 안 되는 상태면 nil. (`hasHighPerformanceDisplay`는 만들 때만 본다)
    private func desiredMode() -> VirtualDisplayMode? {
        guard settings.fitToClientEnabled, session(), port.isAvailable else { return nil }
        // 이미 만든 뒤 클라이언트 화면 정보만 사라진 경우(세션 신호 만료·피어 연결 끊김)는 마지막 모드를 유지한다.
        // 세션이 끝날 때 제거한다. 접속을 끊을 때마다 가상 디스플레이를 지웠다 목표 해상도를 적용했다 되돌리는 깜빡임을 막는다.
        guard let client = clientDisplay() else { return currentMode }
        if currentMode == nil, port.hasHighPerformanceDisplay || physicalDisplayFits() { return nil }
        return VirtualDisplayMode(client: client, hiDPI: settings.virtualDisplayHiDPI)
    }

    private func removalReason() -> String {
        if !settings.fitToClientEnabled { return "클라이언트 화면에 맞추기 꺼짐 → 가상 디스플레이 제거" }
        return "접속 해제 → 가상 디스플레이 제거"
    }

    private func create(_ mode: VirtualDisplayMode) {
        guard canAttempt(mode) else { return }
        willCreate?()
        if port.create(mode: mode) {
            currentMode = mode
            resetAttempts()
            report("가상 디스플레이 생성: \(describe(mode))")
        } else {
            recordFailure(mode, "가상 디스플레이 생성 실패: \(describe(mode))")
        }
        onChange?()
    }

    private func changeMode(to mode: VirtualDisplayMode) {
        guard canAttempt(mode) else { return }
        // HiDPI 여부가 바뀌면 제자리 변경이 먹지 않으므로(macOS가 무시한다) 지우고 새로 만든다.
        let sameKind = currentMode?.hiDPI == mode.hiDPI
        if sameKind, port.update(mode: mode) {
            currentMode = mode
            resetAttempts()
            report("가상 디스플레이 모드 변경: \(describe(mode))")
        } else {
            // 모드 변경이 안 되면(예: 처음 만든 최대 크기를 넘음) 지우고 새로 만든다.
            port.remove()
            if port.create(mode: mode) {
                currentMode = mode
                resetAttempts()
                report("가상 디스플레이 다시 생성: \(describe(mode))")
            } else {
                currentMode = nil
                recordFailure(mode, "가상 디스플레이 모드 변경 실패: \(describe(mode))")
                didRemove?()
            }
        }
        onChange?()
    }

    private func removeNow(reason: String) {
        port.remove()
        currentMode = nil
        report(reason)
        didRemove?()
        onChange?()
    }

    // MARK: 재시도

    private func canAttempt(_ mode: VirtualDisplayMode) -> Bool {
        if failedMode != mode { resetAttempts() }
        guard attempts < maxAttempts else { return false }
        return clock.now >= nextAttemptAt
    }

    private func recordFailure(_ mode: VirtualDisplayMode, _ message: String) {
        failedMode = mode
        attempts += 1
        nextAttemptAt = clock.now.addingTimeInterval(retryInterval)
        report(attempts >= maxAttempts
            ? "\(message) — \(attempts)회 시도 후 중단" : "\(message) — \(Int(retryInterval))초 뒤 재시도")
    }

    private func resetAttempts() {
        failedMode = nil
        attempts = 0
        nextAttemptAt = .distantPast
    }

    private func describe(_ mode: VirtualDisplayMode) -> String {
        let size = mode.pointSize
        return "\(size.width)×\(size.height)" + (mode.hiDPI ? " HiDPI" : "")
    }

    private func report(_ message: String) { lastMessage = message }
}
