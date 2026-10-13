/// 클립보드 공유 설정 저장소 포트. Mac마다 따로 저장하고, 앱이 재시작돼도 유지된다.
public protocol ClipboardSettingsStoring: AnyObject {
    /// 클립보드 공유 사용 여부. 기본값 false.
    var clipboardSyncEnabled: Bool { get set }
}

/// 메모리 구현 (기본값·테스트용).
public final class InMemoryClipboardSettings: ClipboardSettingsStoring {
    public var clipboardSyncEnabled = false
    public init() {}
}
