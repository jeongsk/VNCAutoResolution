import VNCAutoResolutionCore

/// 테스트용 가상 디스플레이 포트. 호출을 기록한다.
final class FakeVirtualDisplay: VirtualDisplayControlling {
    var isAvailable = true
    var hasHighPerformanceDisplay = false
    var createSucceeds = true
    var updateSucceeds = true
    private(set) var isActive = false
    private(set) var mode: VirtualDisplayMode?
    private(set) var created: [VirtualDisplayMode] = []
    private(set) var updated: [VirtualDisplayMode] = []
    private(set) var removeCount = 0

    var activeSize: (width: Int, height: Int)? { mode.map { $0.pointSize } }

    func create(mode: VirtualDisplayMode) -> Bool {
        created.append(mode)
        guard createSucceeds else { return false }
        isActive = true
        self.mode = mode
        return true
    }

    func update(mode: VirtualDisplayMode) -> Bool {
        updated.append(mode)
        guard isActive, updateSucceeds else { return false }
        self.mode = mode
        return true
    }

    func remove() {
        guard isActive else { return }
        removeCount += 1
        isActive = false
        mode = nil
    }
}
