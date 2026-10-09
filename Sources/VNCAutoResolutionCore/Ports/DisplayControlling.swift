/// 디스플레이 포트: 해상도 목록 조회, 현재 해상도 조회, 해상도 적용.
public protocol DisplayControlling {
    /// 선택 가능한 해상도 목록 (중복 제거, 큰 해상도부터).
    func availableOptions() -> [ResolutionOption]
    func currentOption() -> ResolutionOption?
    /// 해당 id의 해상도로 바꾼다. 성공하면 true.
    func apply(id: String) -> Bool
}
