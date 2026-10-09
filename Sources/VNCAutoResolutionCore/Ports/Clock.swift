import Foundation

/// 시계 포트: 현재 시각을 제공한다. 테스트에서 직접 조정할 수 있게 주입한다.
public protocol Clock {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}
