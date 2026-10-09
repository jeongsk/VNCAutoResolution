import VNCAutoResolutionCore

/// 테스트용 화면 포트. `mainScreen`을 직접 바꾼다.
final class FakeScreen: ScreenReading {
    var mainScreen: ScreenInfo?
    init(_ screen: ScreenInfo? = ScreenInfo(width: 1512, height: 982, scale: 2)) { mainScreen = screen }
}
