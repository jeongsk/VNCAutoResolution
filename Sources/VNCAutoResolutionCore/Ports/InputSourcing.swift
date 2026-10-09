/// 입력 소스(키보드) 하나의 상태: ID와 한국어 여부.
public struct InputState: Equatable, Sendable {
    public let id: String
    public let isKorean: Bool
    public init(id: String, isKorean: Bool) {
        self.id = id
        self.isKorean = isKorean
    }
}

/// 입력 소스 포트: 현재 입력 소스를 조회하고, 선택 가능한 목록에서 하나를 적용한다.
/// 대체(fallback) 선택은 코어(`InputSourceSelector`)가 하므로 포트는 목록과 ID 선택만 노출한다.
/// 로컬 입력 소스가 바뀌었다는 알림은 앱이 `InputSyncController.localInputChanged()`로 전달한다.
public protocol InputSourcing: AnyObject {
    /// 지금 선택된 키보드 입력 소스. 알 수 없으면 nil.
    var current: InputState? { get }
    /// 선택할 수 있는 키보드 입력 소스 목록.
    var available: [InputState] { get }
    /// 해당 ID의 입력 소스를 선택한다. 요청이 접수되면 true (실제 반영 여부는 `current`로 다시 확인한다).
    func select(id: String) -> Bool
}
