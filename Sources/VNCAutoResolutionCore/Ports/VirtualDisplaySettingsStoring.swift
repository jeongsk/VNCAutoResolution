/// 가상 디스플레이 설정 저장소 포트. 앱이 재시작돼도 유지된다.
public protocol VirtualDisplaySettingsStoring: AnyObject {
    /// "클라이언트 화면에 맞추기" 사용 여부. 기본값 true.
    var fitToClientEnabled: Bool { get set }
    /// "HiDPI 가상 디스플레이" 사용 여부. 기본값 false.
    var virtualDisplayHiDPI: Bool { get set }
}

/// 메모리 구현 (기본값·테스트용).
public final class InMemoryVirtualDisplaySettings: VirtualDisplaySettingsStoring {
    public var fitToClientEnabled = true
    public var virtualDisplayHiDPI = false
    public init() {}
}
