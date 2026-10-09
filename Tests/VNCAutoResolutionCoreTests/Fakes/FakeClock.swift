import Foundation
import VNCAutoResolutionCore

/// 테스트용 시계. `now`를 직접 조정한다.
final class FakeClock: Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
