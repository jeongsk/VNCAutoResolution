/// 실제 화면(모니터·더미 플러그)의 모드 중 클라이언트 화면에 맞는 것을 고른다.
///
/// 맞는 모드가 있으면 가상 디스플레이를 만들지 않고 그 모드로 바꾼다. (가상 디스플레이는 헤드리스에서 제거가
/// 실패해 화면이 남는 일이 있고, 실제 모니터가 있으면 메인 화면이 되지 못한다 — #13)
public enum ClientModeMatcher {
    /// 맞춘 모드가 클라이언트 화면 넓이의 이 비율보다 작으면 가상 디스플레이가 낫다고 본다.
    static let minAreaRatio = 0.7

    /// 클라이언트 화면(포인트) 안에 들어가는 모드 중 가장 넓은 것. HiDPI를 원하면 HiDPI 모드만 본다.
    /// 해상도가 몇 개 없는 화면(모니터 없는 맥미니의 기본 화면 등)이면 nil.
    public static func bestOption(
        for client: ClientDisplay, hiDPI: Bool, in options: [ResolutionOption]
    ) -> ResolutionOption? {
        guard options.count >= ResolutionController.fewOptionsThreshold else { return nil }
        let wantHiDPI = hiDPI && client.scale >= 2
        let minArea = Double(client.width * client.height) * minAreaRatio
        return options
            .filter { $0.isHiDPI == wantHiDPI && $0.width <= client.width && $0.height <= client.height }
            .filter { Double($0.width * $0.height) >= minArea }
            .max { ($0.width * $0.height, $0.pixelWidth) < ($1.width * $1.height, $1.pixelWidth) }
    }
}
