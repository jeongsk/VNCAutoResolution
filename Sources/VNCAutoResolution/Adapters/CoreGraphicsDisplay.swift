import CoreGraphics
import VNCAutoResolutionCore

/// 디스플레이 포트의 실제 구현: CoreGraphics 공개 API.
struct CoreGraphicsDisplay: DisplayControlling {
    private var display: CGDirectDisplayID { CGMainDisplayID() }

    private func option(_ mode: CGDisplayMode) -> ResolutionOption {
        ResolutionOption(width: mode.width, height: mode.height,
                         pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight)
    }

    private func allModes() -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
        return modes.filter { $0.isUsableForDesktopGUI() }
    }

    /// 중복을 제거하고 큰 해상도부터 정렬한 목록.
    func availableOptions() -> [ResolutionOption] {
        var seen = Set<String>()
        return allModes()
            .map(option)
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.width, $0.height, $0.pixelWidth) > ($1.width, $1.height, $1.pixelWidth) }
    }

    func currentOption() -> ResolutionOption? {
        CGDisplayCopyDisplayMode(display).map(option)
    }

    /// 해당 id의 해상도로 바꾼다. 같은 크기가 여러 주사율로 있으면 가장 높은 주사율을 고른다.
    func apply(id: String) -> Bool {
        let candidates = allModes().filter { option($0).id == id }
        guard let mode = candidates.max(by: { $0.refreshRate < $1.refreshRate }) else { return false }
        if currentOption()?.id == id { return true }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        // 로그아웃하면 원래 설정으로 돌아가도록 세션 범위로만 적용한다.
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
