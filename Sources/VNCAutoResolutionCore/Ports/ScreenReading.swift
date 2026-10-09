/// 메인 화면 정보: 포인트 크기와 배율(backingScaleFactor).
public struct ScreenInfo: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let scale: Double
    public init(width: Int, height: Int, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}

/// 화면 포트: 이 Mac의 메인 화면 크기를 읽는다. 읽을 수 없으면 nil.
/// 화면 구성이 바뀌었다는 알림은 앱이 `AppCore.screenConfigurationChanged()`로 전달한다.
public protocol ScreenReading: AnyObject {
    var mainScreen: ScreenInfo? { get }
}

/// 화면을 읽지 않는 기본 구현. (화면 정보를 보내지 않는다)
public final class NullScreenReader: ScreenReading {
    public init() {}
    public var mainScreen: ScreenInfo? { nil }
}
