import AppKit
import VNCAutoResolutionCore

/// 메인 화면(메뉴 막대가 있는 화면)의 포인트 크기와 `backingScaleFactor`를 읽는다. 메인 스레드에서 부른다.
final class MainScreenReader: ScreenReading {
    var mainScreen: ScreenInfo? {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return nil }
        let size = screen.frame.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        return ScreenInfo(
            width: Int(size.width.rounded()), height: Int(size.height.rounded()),
            scale: Double(screen.backingScaleFactor))
    }
}
