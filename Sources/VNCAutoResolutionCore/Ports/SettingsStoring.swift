/// 설정 저장소 포트. 앱이 재시작돼도 유지돼야 하는 값들.
public protocol SettingsStoring: AnyObject {
    /// 접속 시 자동 변경 사용 여부 (기본값 true).
    var autoChangeEnabled: Bool { get set }
    /// 목표 해상도 id. 비어 있으면 선택 안 함.
    var targetResolutionID: String { get set }
    /// 접속 전 해상도 id. 앱이 재시작돼도 복원할 수 있게 저장한다.
    var originalResolutionID: String? { get set }
}
