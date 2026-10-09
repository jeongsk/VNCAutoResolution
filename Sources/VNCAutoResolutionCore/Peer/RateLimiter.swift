import Foundation

/// 고정 창 방식 빈도 제한. 창 하나(`interval`) 안에 `maxCount`개까지 허용한다.
public struct RateLimiter {
    public let maxCount: Int
    public let interval: TimeInterval
    private var windowStart: Date?
    private var count = 0

    public init(maxCount: Int, interval: TimeInterval) {
        self.maxCount = maxCount
        self.interval = interval
    }

    /// 지금 메시지 하나를 받아도 되는지. 허용하면 카운트를 올린다.
    public mutating func allow(at now: Date) -> Bool {
        if let start = windowStart, now >= start, now.timeIntervalSince(start) < interval {
            count += 1
        } else {
            windowStart = now
            count = 1
        }
        return count <= maxCount
    }
}
