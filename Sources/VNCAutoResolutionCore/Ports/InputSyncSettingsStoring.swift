/// 입력 동기화 설정 저장소 포트. 앱이 재시작돼도 유지된다.
public protocol InputSyncSettingsStoring: AnyObject {
    /// 동기화 사용 여부 (false = 일시정지). 기본값 true.
    var inputSyncEnabled: Bool { get set }
    /// "원격 세션 중에만" 동기화 여부. 기본값 true.
    var inputSyncOnlyDuringRemote: Bool { get set }
}

/// 메모리 구현 (기본값·테스트용).
public final class InMemoryInputSyncSettings: InputSyncSettingsStoring {
    public var inputSyncEnabled = true
    public var inputSyncOnlyDuringRemote = true
    public init() {}
}

/// 입력 소스 포트를 주입하지 않은 코어용: 아무것도 하지 않는다.
final class NullInputSource: InputSourcing {
    var current: InputState? { nil }
    var available: [InputState] { [] }
    func select(id: String) -> Bool { false }
}

final class NullViewerAppDetector: ViewerAppDetecting {
    var runningBundleIDs: [String] { [] }
}
