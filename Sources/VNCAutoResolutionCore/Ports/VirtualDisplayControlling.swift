/// 가상 디스플레이 모드. width·height는 픽셀 단위다.
/// (1배율이면 포인트 크기 그대로, HiDPI면 포인트 × 2. 계산은 `VirtualDisplayMode(client:hiDPI:)`.)
/// 비공개 API(`CGVirtualDisplayMode`)는 HiDPI일 때 포인트 크기를 받으므로, 어댑터가 `pointSize`로 바꿔 넘긴다.
public struct VirtualDisplayMode: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let hiDPI: Bool

    public init(width: Int, height: Int, hiDPI: Bool) {
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
    }

    /// 클라이언트 화면(포인트 + 배율)에서 모드를 계산한다.
    /// HiDPI를 켜도 클라이언트 배율이 2 미만(1배율 화면)이면 HiDPI로 만들 이유가 없어 1배율로 만든다.
    /// macOS의 HiDPI 배율은 항상 2라서, 클라이언트 배율이 3이어도 포인트 × 2로 만든다.
    public init(client: ClientDisplay, hiDPI: Bool) {
        if hiDPI, client.scale >= 2 {
            self.init(width: client.width * 2, height: client.height * 2, hiDPI: true)
        } else {
            self.init(width: client.width, height: client.height, hiDPI: false)
        }
    }

    /// 화면에 보이는 포인트 크기 (HiDPI면 픽셀 ÷ 2).
    public var pointSize: (width: Int, height: Int) {
        hiDPI ? (width / 2, height / 2) : (width, height)
    }
}

/// 가상 디스플레이 포트: 사용 가능 여부, 생성·모드 변경·제거.
/// 어댑터는 비공개 API를 런타임에만 찾아 쓰고, 객체를 강한 참조로 들고 있다가 `remove()`에서 놓는다.
public protocol VirtualDisplayControlling: AnyObject {
    /// 이 OS에서 가상 디스플레이를 만들 수 있는지. (클래스·셀렉터가 있는지)
    var isAvailable: Bool { get }
    /// 화면 공유 고성능 모드의 가상 디스플레이("Screen Sharing Virtual Display")가 이미 있는지.
    var hasHighPerformanceDisplay: Bool { get }
    /// 이 포트가 만든 가상 디스플레이가 지금 있는지.
    var isActive: Bool { get }
    /// 지금 가상 디스플레이의 포인트 크기. (`CGDisplayBounds`로 읽는다. 없으면 nil)
    var activeSize: (width: Int, height: Int)? { get }
    /// 가상 디스플레이를 만든다. 성공하면 true. 어떤 화면의 미러로도 만들지 않는다.
    func create(mode: VirtualDisplayMode) -> Bool
    /// 이미 있는 가상 디스플레이의 모드를 바꾼다. 성공하면 true.
    func update(mode: VirtualDisplayMode) -> Bool
    /// 가상 디스플레이를 없앤다. 없으면 아무 일도 없다.
    func remove()
}

/// 가상 디스플레이 포트를 주입하지 않은 코어용: 항상 사용 불가.
final class NullVirtualDisplay: VirtualDisplayControlling {
    var isAvailable: Bool { false }
    var hasHighPerformanceDisplay: Bool { false }
    var isActive: Bool { false }
    var activeSize: (width: Int, height: Int)? { nil }
    func create(mode: VirtualDisplayMode) -> Bool { false }
    func update(mode: VirtualDisplayMode) -> Bool { false }
    func remove() {}
}
