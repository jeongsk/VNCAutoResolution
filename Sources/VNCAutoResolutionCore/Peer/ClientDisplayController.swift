import Foundation

/// 호스트가 알고 있는 클라이언트 화면. width·height는 포인트, scale은 배율.
public struct ClientDisplay: Equatable, Sendable {
    public let deviceID: String
    public let width: Int
    public let height: Int
    public let scale: Double

    public init(deviceID: String, width: Int, height: Int, scale: Double) {
        self.deviceID = deviceID
        self.width = width
        self.height = height
        self.scale = scale
    }

    /// 메뉴 표시용: "1512×982 (@2x)"
    public var sizeLabel: String {
        let scaleText = scale == scale.rounded() ? String(Int(scale)) : String(format: "%g", scale)
        return "\(width)×\(height) (@\(scaleText)x)"
    }
}

/// 클라이언트 화면 정보(`display` 메시지)의 송신과 수신을 맡는다.
///
/// - 송신: 뷰어 앱이 실행 중인 쪽만 보낸다. 보내는 때는 세션 시작, 새 피어 연결, 화면 구성 변경.
///   ("뷰어 쪽" 판정과 세션 시작 판정은 `InputSyncController`의 것을 그대로 쓴다.)
/// - 수신: 세션 신호가 활성인 피어가 보낸 가장 최근 `display`를 `clientDisplay`로 든다.
///   그 피어의 세션 신호가 만료되거나 연결이 끊기면 비운다.
///
/// 스레드: 메인 스레드 전용 (PeerManager와 같다).
public final class ClientDisplayController {
    /// 허용하는 화면 크기·배율 범위. 벗어나면 잘못된 메시지로 보고 무시한다.
    static let sizeRange = 1...16384
    static let scaleRange = 1.0...8.0

    /// 호스트 쪽 상태: 세션이 활성인 피어가 보낸 가장 최근 화면. 없으면 nil.
    public private(set) var clientDisplay: ClientDisplay?
    /// `clientDisplay`가 바뀔 때만 불린다.
    public var onChange: (() -> Void)?

    private struct Report {
        let display: ClientDisplay
        let sequence: Int
    }

    private let screen: ScreenReading
    private let peers: PeerManager
    private let inputSync: InputSyncController
    private var reports: [String: Report] = [:]   // deviceID -> 마지막 보고
    private var activeSeen: Set<String> = []      // 세션이 활성이던 걸 본 피어
    private var sequence = 0

    public init(screen: ScreenReading, peers: PeerManager, inputSync: InputSyncController) {
        self.screen = screen
        self.peers = peers
        self.inputSync = inputSync
    }

    // MARK: 송신 (클라이언트)

    /// 뷰어 앱이 실행 중이면 현재 메인 화면을 모든 피어에 보낸다. 세션 시작, 새 피어, 화면 구성 변경 때 부른다.
    public func sendIfViewer() {
        guard inputSync.isViewerSide, let info = screen.mainScreen else { return }
        peers.broadcast(.display(
            deviceID: peers.deviceID, width: info.width, height: info.height, scale: info.scale))
    }

    // MARK: 수신 (호스트)

    /// 피어가 보낸 `display`를 기록한다. 세션이 활성인 피어의 것만 `clientDisplay`가 된다.
    public func handle(_ message: PeerMessage, from peer: PeerManager.Peer) {
        guard case .display(_, let width, let height, let scale) = message,
              Self.sizeRange.contains(width), Self.sizeRange.contains(height),
              scale.isFinite, Self.scaleRange.contains(scale) else { return }
        sequence += 1
        reports[peer.deviceID] = Report(
            display: ClientDisplay(deviceID: peer.deviceID, width: width, height: height, scale: scale),
            sequence: sequence)
        refresh()
    }

    /// 피어 목록이나 세션 신호가 바뀌었을 때 부른다. 끊긴·만료된 피어의 보고를 비우고 `clientDisplay`를 다시 정한다.
    public func refresh() {
        let connected = Set(peers.peers.map(\.deviceID))
        for id in Array(reports.keys) {
            if connected.contains(id), inputSync.isSessionActive(peer: id) {
                activeSeen.insert(id)
            } else if !connected.contains(id) || activeSeen.contains(id) {
                // 끊겼거나, 활성이었다가 만료·종료됨. (아직 활성인 걸 못 본 피어는 세션 신호를 기다린다.)
                reports.removeValue(forKey: id)
                activeSeen.remove(id)
            }
        }
        activeSeen.formIntersection(connected)
        let best = reports.values
            .filter { inputSync.isSessionActive(peer: $0.display.deviceID) }
            .max { $0.sequence < $1.sequence }?.display
        if best != clientDisplay {
            clientDisplay = best
            onChange?()
        }
    }
}
