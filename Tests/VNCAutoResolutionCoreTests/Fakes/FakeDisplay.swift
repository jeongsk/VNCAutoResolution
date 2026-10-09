import VNCAutoResolutionCore

/// 테스트용 디스플레이 포트. 적용 호출을 기록한다.
final class FakeDisplay: DisplayControlling {
    static let hd = ResolutionOption(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080)
    static let small = ResolutionOption(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720)
    static let retina = ResolutionOption(width: 1440, height: 900, pixelWidth: 2880, pixelHeight: 1800)

    var options: [ResolutionOption] = [hd, retina, small]
    var current: ResolutionOption? = hd
    var applySucceeds = true
    private(set) var applied: [String] = []

    func availableOptions() -> [ResolutionOption] { options }
    func currentOption() -> ResolutionOption? { current }

    func apply(id: String) -> Bool {
        applied.append(id)
        guard applySucceeds, let option = options.first(where: { $0.id == id }) else { return false }
        current = option
        return true
    }
}
