import Foundation

/// 재연결 대기 시간: base * 2^attempt, 상한 max.
public struct Backoff: Equatable, Sendable {
    public var base: TimeInterval
    public var max: TimeInterval

    public init(base: TimeInterval = 1, max: TimeInterval = 30) {
        self.base = base
        self.max = max
    }

    /// `attempt`는 0부터. 0번째 재시도는 base만큼 기다린다.
    public func delay(attempt: Int) -> TimeInterval {
        let exponent = Swift.min(Swift.max(attempt, 0), 20)
        return Swift.min(base * Double(1 << exponent), max)
    }
}
