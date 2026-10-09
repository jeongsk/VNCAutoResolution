/// 메뉴의 "현재 해상도" 문구.
/// 가상 디스플레이에서는 현재 모드를 읽을 수 없고(nil) 해상도 컨트롤러도 멈춰 있으므로,
/// 가상 디스플레이가 사용 중이면 그 크기를 보여 준다.
public enum CurrentResolutionLabel {
    public static func text(
        options: [ResolutionOption], currentID: String?, virtualDisplay: VirtualDisplayController.Status
    ) -> String {
        if case .active(let width, let height) = virtualDisplay {
            return "\(width) × \(height) (가상 디스플레이)"
        }
        return options.first { $0.id == currentID }?.label ?? currentID ?? "알 수 없음"
    }
}
