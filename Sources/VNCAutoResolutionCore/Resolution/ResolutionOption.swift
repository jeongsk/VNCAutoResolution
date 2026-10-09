/// 메인 디스플레이에서 고를 수 있는 해상도 하나. OS 타입에 의존하지 않는 값 타입.
public struct ResolutionOption: Hashable, Identifiable, Sendable {
    public let width: Int        // 포인트 단위 (화면에 보이는 크기)
    public let height: Int
    public let pixelWidth: Int   // 실제 픽셀
    public let pixelHeight: Int

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var id: String { "\(width)x\(height)@\(pixelWidth)x\(pixelHeight)" }
    public var isHiDPI: Bool { pixelWidth > width }
    public var label: String { "\(width) × \(height)" + (isHiDPI ? " (HiDPI)" : "") }
}
