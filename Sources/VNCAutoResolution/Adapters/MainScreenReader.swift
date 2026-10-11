import AppKit
import VNCAutoResolutionCore

/// 메인 화면(메뉴 막대가 있는 화면)의 포인트 크기와 `backingScaleFactor`를 읽는다. 메인 스레드에서 부른다.
///
/// 노치가 있는 화면은 위쪽 안전 영역(노치 높이)을 뺀다. 전체 화면 앱은 노치 아래에만 그려지므로,
/// 뷰어를 전체 화면으로 띄우면 실제로 보이는 영역은 이 크기다. 빼지 않으면 화면 비율이 달라져 옆에 여백이 생긴다.
final class MainScreenReader: ScreenReading {
    var mainScreen: ScreenInfo? {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return nil }
        let width = screen.frame.width
        let height = screen.frame.height - Self.fullScreenTopInset(of: screen)
        guard width >= 1, height >= 1 else { return nil }
        return ScreenInfo(
            width: Int(width.rounded()), height: Int(height.rounded()),
            scale: Double(screen.backingScaleFactor))
    }

    /// 전체 화면 창이 비우는 위쪽 높이. 노치가 없으면 0.
    /// 노치 화면의 전체 화면 창은 메뉴 막대 바로 아래에서 시작한다(14인치: 노치 32pt, 메뉴 막대 33pt).
    /// 메뉴 막대를 자동으로 숨기면 `visibleFrame`이 화면 끝까지 닿으므로 노치 높이로 대신한다.
    private static func fullScreenTopInset(of screen: NSScreen) -> CGFloat {
        let notch = screen.safeAreaInsets.top
        guard notch > 0 else { return 0 }
        return max(notch, screen.frame.maxY - screen.visibleFrame.maxY)
    }
}
