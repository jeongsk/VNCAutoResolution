import Foundation
import os

/// 한/영 입력 소스 동기화. 로컬 입력 변경을 피어에 절대 상태로 보내고, 받은 상태를 적용한다.
/// 에코 억제·세션 게이트·세션 신호 유지를 여기서 처리한다. (에코 억제 아이디어는 HangulSync에서 옮김)
///
/// 스레드: 메인 스레드 전용 (PeerManager와 같다).
public final class InputSyncController {
    public enum Status: Equatable {
        case paused    // 사용자가 일시정지함
        case waiting   // 켜져 있지만 원격 세션 조건이 없어 대기 중
        case active    // 동기화 중
    }

    /// 원격 상태로 적용한 ID의 알림을 에코로 보고 무시하는 시간(초).
    public let echoWindow: TimeInterval
    /// 피어 세션 신호 유효시간(초).
    public let sessionTTL: TimeInterval
    /// 로컬 세션 신호 재전송 주기(초).
    public let sessionRefresh: TimeInterval
    /// 적용 직후 확인해 안 먹었을 때 재시도를 포함한 최대 시도 횟수.
    static let log = Logger(subsystem: "com.jeongsk.VNCAutoResolution", category: "inputsync")
    public let maxApplyAttempts: Int

    public private(set) var lastMessage = ""
    /// 상태가 바뀔 때마다 불린다.
    public var onChange: (() -> Void)?
    /// 로컬 세션이 없다가 시작됐을 때 불린다. (클라이언트 화면 정보 전송용)
    public var onLocalSessionStarted: (() -> Void)?
    /// 새 피어가 붙었을 때 불린다. (로컬 세션 여부와 무관)
    public var onPeerJoined: (() -> Void)?

    private let input: InputSourcing
    private let viewers: ViewerAppDetecting
    private let settings: InputSyncSettingsStoring
    private let peers: PeerManager
    private let clock: Clock

    private var localVNC = false
    private var localViewer = false
    private var peerSessions: [String: Date] = [:]   // deviceID -> 마지막 활성 신호 시각
    private var lastSessionBroadcast = Date.distantPast
    private var knownPeerIDs: Set<String> = []

    /// 마지막으로 보내거나 적용해 상대와 같다고 아는 입력 소스 ID.
    private var lastKnownID: String?
    /// 방금 원격 상태로 적용한 ID와 에코 무시 만료 시각.
    private var applied: (id: String, until: Date)?
    /// 적용 실패로 보고한 ID. 전환이 늦게 반영돼 실제로는 그 입력 소스가 되면 실패 메시지를 지운다.
    /// (도우미 프로세스로 전환하면 이 앱의 현재 입력 값은 알림이 처리된 뒤에야 바뀐다)
    private var failedApplyID: String?

    public init(
        input: InputSourcing,
        viewers: ViewerAppDetecting,
        settings: InputSyncSettingsStoring,
        peers: PeerManager,
        clock: Clock,
        echoWindow: TimeInterval = 1,
        sessionTTL: TimeInterval = 600,
        sessionRefresh: TimeInterval = 240,
        maxApplyAttempts: Int = 3
    ) {
        self.input = input
        self.viewers = viewers
        self.settings = settings
        self.peers = peers
        self.clock = clock
        self.echoWindow = echoWindow
        self.sessionTTL = sessionTTL
        self.sessionRefresh = sessionRefresh
        self.maxApplyAttempts = maxApplyAttempts
    }

    // MARK: 상태

    public var enabled: Bool {
        get { settings.inputSyncEnabled }
        set { settings.inputSyncEnabled = newValue; onChange?() }
    }

    public var onlyDuringRemote: Bool {
        get { settings.inputSyncOnlyDuringRemote }
        set { settings.inputSyncOnlyDuringRemote = newValue; onChange?() }
    }

    /// 현재 로컬 입력 소스. 메뉴 표시용.
    public var currentInput: InputState? { input.current }

    /// 로컬 VNC 세션이나 뷰어 앱이 있는 상태.
    public var isLocalSessionActive: Bool { localVNC || localViewer }

    /// 뷰어 앱이 실행 중인 쪽(클라이언트)인지. 세션 시작 상태와 화면 정보를 먼저 보내는 쪽이다.
    public var isViewerSide: Bool { localViewer }

    /// 이 피어가 유효시간 안에 세션 활성 신호를 보냈는지.
    public func isSessionActive(peer deviceID: String) -> Bool {
        guard let last = peerSessions[deviceID] else { return false }
        return clock.now.timeIntervalSince(last) < sessionTTL
    }

    /// 유효시간 안에 세션 활성 신호를 보낸 피어가 있는지.
    public var isPeerSessionActive: Bool {
        let now = clock.now
        return peerSessions.values.contains { now.timeIntervalSince($0) < sessionTTL }
    }

    /// 원격 세션 중인지(로컬 세션 또는 유효한 피어 세션 신호). 입력 동기화 설정과 무관한 세션 게이트다.
    /// (클립보드 공유도 같은 게이트를 쓴다)
    public var isRemoteSessionActive: Bool { isLocalSessionActive || isPeerSessionActive }

    /// 지금 동기화가 동작해도 되는 상태인지.
    public var syncAllowed: Bool {
        guard enabled else { return false }
        guard onlyDuringRemote else { return true }
        return isRemoteSessionActive
    }

    public var status: Status {
        if !enabled { return .paused }
        return syncAllowed ? .active : .waiting
    }

    // MARK: 이벤트

    /// 로컬 VNC 세션 여부가 바뀌었음을 알린다. (AppCore가 해상도 쪽 클라이언트 상태로 호출)
    public func setLocalVNC(active: Bool) {
        guard active != localVNC else { return }
        let before = isLocalSessionActive
        localVNC = active
        localSessionMayHaveChanged(was: before)
    }

    /// 뷰어 앱 실행/종료가 일어났음을 알린다. 실행 중인 앱을 다시 읽는다.
    public func viewerAppsChanged() {
        let running = viewers.runningBundleIDs.contains(where: ViewerApps.isViewer(bundleID:))
        guard running != localViewer else { return }
        let before = isLocalSessionActive
        localViewer = running
        localSessionMayHaveChanged(was: before)
    }

    /// 로컬 입력 소스가 바뀌었다는 알림(TIS 분산 알림)을 받았을 때 부른다.
    public func localInputChanged() {
        defer { onChange?() }
        guard let state = input.current else { Self.log.debug("local: 현재 값 없음"); return }
        if let failed = failedApplyID, state.id == failed {
            failedApplyID = nil
            lastMessage = ""
        }
        // 동기화 조건이 안 되면 보내지 않는다. 나중에 같은 ID로 돌아와도 보내도록 기억을 지운다.
        guard syncAllowed else {
            Self.log.debug("local \(state.id, privacy: .public): 동기화 조건 아님")
            lastKnownID = nil; return
        }
        // 에코 억제: 방금 원격 상태로 적용한 ID와 같고 유효시간 안이면 전파하지 않는다.
        if let applied, state.id == applied.id, clock.now < applied.until {
            Self.log.debug("local \(state.id, privacy: .public): 에코 억제")
            return
        }
        guard state.id != lastKnownID else {
            Self.log.debug("local \(state.id, privacy: .public): 마지막 값과 같아 건너뜀")
            return
        }
        Self.log.debug("local \(state.id, privacy: .public): 전송 (이전 \(self.lastKnownID ?? "nil", privacy: .public), applied \(self.applied?.id ?? "nil", privacy: .public))")
        applied = nil   // 다른 ID로 실제 전환 → 억제 해제
        lastKnownID = state.id
        peers.broadcast(.input(deviceID: peers.deviceID, sourceID: state.id, isKorean: state.isKorean))
    }

    /// 피어 목록이 바뀌었을 때 부른다. 새 피어가 붙었고 로컬 세션 중이면 세션 신호와 현재 상태를 보낸다.
    public func peersChanged() {
        let ids = Set(peers.peers.map(\.deviceID))
        let joined = !ids.subtracting(knownPeerIDs).isEmpty
        knownPeerIDs = ids
        if joined, isLocalSessionActive {
            announceSession(active: true)
            sendCurrentStateIfInitiator()
        }
        if joined { onPeerJoined?() }
    }

    /// 피어가 보낸 메시지(hello 이후 검증된 것)를 처리한다.
    public func handle(_ message: PeerMessage, from peer: PeerManager.Peer) {
        switch message {
        case .session(_, let active):
            if active { peerSessions[peer.deviceID] = clock.now } else { peerSessions.removeValue(forKey: peer.deviceID) }
            onChange?()
        case .input(_, let sourceID, let isKorean):
            applyRemote(id: sourceID, isKorean: isKorean)
            onChange?()
        case .hello, .display, .clipboard, .fileOffer, .fileAnswer, .dataChannel:
            break   // 코어의 다른 컨트롤러가 처리한다.
        }
    }

    /// 주기 작업(수 초마다): 뷰어 앱 재확인, 세션 신호 재전송, 피어 세션 만료 정리.
    public func tick() {
        viewerAppsChanged()
        if isLocalSessionActive, clock.now.timeIntervalSince(lastSessionBroadcast) >= sessionRefresh {
            announceSession(active: true)
        }
        let now = clock.now
        let before = peerSessions.count
        peerSessions = peerSessions.filter { now.timeIntervalSince($0.value) < sessionTTL }
        if peerSessions.count != before { onChange?() }
    }

    // MARK: 내부

    private func localSessionMayHaveChanged(was before: Bool) {
        let after = isLocalSessionActive
        defer { onChange?() }
        guard after != before else { return }
        announceSession(active: after)
        if after {
            sendCurrentStateIfInitiator()
            onLocalSessionStarted?()
        }
    }

    private func announceSession(active: Bool) {
        lastSessionBroadcast = clock.now
        peers.broadcast(.session(deviceID: peers.deviceID, active: active))
    }

    /// 세션 시작 시 현재 상태를 한 번 보낸다. 양쪽이 동시에 보내 서로 뒤바뀌지 않도록,
    /// 뷰어를 보는 쪽(클라이언트)은 항상 보내고, VNC만 있는 쪽(호스트)은 상대 세션 신호가 이미 있으면 보내지 않는다.
    private func sendCurrentStateIfInitiator() {
        guard syncAllowed, localViewer || !isPeerSessionActive, let state = input.current else { return }
        Self.log.debug("initiator: 현재 상태 전송 \(state.id, privacy: .public)")
        lastKnownID = state.id
        applied = nil
        peers.broadcast(.input(deviceID: peers.deviceID, sourceID: state.id, isKorean: state.isKorean))
    }

    private func applyRemote(id: String, isKorean: Bool) {
        guard syncAllowed else { Self.log.debug("recv \(id, privacy: .public): 동기화 조건 아님"); return }
        guard let target = InputSourceSelector.select(id: id, isKorean: isKorean, from: input.available) else {
            lastMessage = "입력 소스 적용 실패: 맞는 입력 소스 없음"
            return
        }
        // 이미 같은 상태면 적용하지 않는다.
        let before = input.current?.id
        if before == target.id {
            Self.log.debug("recv \(id, privacy: .public): 이미 같음(현재 \(before ?? "nil", privacy: .public)) 건너뜀")
            lastKnownID = target.id; return
        }
        Self.log.debug("recv \(id, privacy: .public): 적용 \(target.id, privacy: .public) (현재 \(before ?? "nil", privacy: .public))")

        // 알림이 먼저 도착해도 에코로 걸러지도록, 적용 전에 억제를 건다.
        applied = (target.id, clock.now.addingTimeInterval(echoWindow))
        lastKnownID = target.id
        // TISSelectInputSource가 불안정해서 적용 직후 다시 확인하고, 안 먹었으면 재시도한다.
        for _ in 0..<max(1, maxApplyAttempts) {
            let ok = input.select(id: target.id)
            let after = input.current?.id
            Self.log.debug("recv \(id, privacy: .public): select=\(ok, privacy: .public) 확인 \(after ?? "nil", privacy: .public)")
            if after == target.id {
                lastMessage = ""
                failedApplyID = nil
                return
            }
        }
        failedApplyID = target.id
        lastMessage = "입력 소스 적용 실패: \(target.id)"
    }
}
