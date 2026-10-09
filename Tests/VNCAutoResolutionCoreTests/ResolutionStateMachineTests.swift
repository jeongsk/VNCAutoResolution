import XCTest
@testable import VNCAutoResolutionCore

/// 해상도 상태 머신: 시작 시 복원, 실패 재시도, 디스플레이 변경, 해상도 목록 안내.
final class ResolutionStateMachineTests: XCTestCase {
    private var vnc: FakeVNCDetector!
    private var display: FakeDisplay!
    private var settings: FakeSettingsStore!
    private var clock: FakeClock!

    override func setUp() {
        vnc = FakeVNCDetector()
        display = FakeDisplay()
        settings = FakeSettingsStore()
        clock = FakeClock()
        settings.targetResolutionID = FakeDisplay.small.id
    }

    private func makeCore() -> AppCore {
        AppCore(vnc: vnc, display: display, settings: settings, clock: clock)
    }

    // MARK: 시작 시 복원

    func testStartupRestoresSavedOriginalWhenNoSession() {
        settings.originalResolutionID = FakeDisplay.retina.id
        let core = makeCore()
        core.tick()

        XCTAssertEqual(display.applied, [FakeDisplay.retina.id])
        XCTAssertNil(settings.originalResolutionID)
    }

    func testStartupKeepsOriginalWhenSessionIsActive() {
        settings.originalResolutionID = FakeDisplay.retina.id
        vnc.clients = ["10.0.0.2"]
        let core = makeCore()
        core.tick()

        XCTAssertEqual(settings.originalResolutionID, FakeDisplay.retina.id)
        XCTAssertFalse(display.applied.contains(FakeDisplay.retina.id))
    }

    func testStartupWithoutSavedOriginalDoesNothing() {
        let core = makeCore()
        core.tick()
        XCTAssertEqual(display.applied, [])
    }

    // MARK: 재시도

    func testApplyFailureRetriesAtIntervalAndSucceeds() {
        display.applySucceeds = false
        vnc.clients = ["10.0.0.2"]
        let core = makeCore()
        core.tick()
        XCTAssertEqual(display.applied.count, 1)
        XCTAssertTrue(core.resolution.isRetrying)

        clock.advance(by: 5)
        core.tick()
        XCTAssertEqual(display.applied.count, 1, "간격 전에는 재시도하지 않는다")

        display.applySucceeds = true
        clock.advance(by: 5)
        core.tick()
        XCTAssertEqual(display.applied.count, 2)
        XCTAssertEqual(core.resolution.currentID, FakeDisplay.small.id)
        XCTAssertFalse(core.resolution.isRetrying)

        clock.advance(by: 60)
        core.tick()
        XCTAssertEqual(display.applied.count, 2, "성공 후에는 더 시도하지 않는다")
    }

    func testRetryStopsAfterMaxAttemptsAndReportsIt() {
        display.applySucceeds = false
        vnc.clients = ["10.0.0.2"]
        let core = makeCore()
        core.tick()
        for _ in 0..<20 {
            clock.advance(by: core.resolution.retryInterval)
            core.tick()
        }

        XCTAssertEqual(display.applied.count, 1 + core.resolution.maxRetryAttempts)
        XCTAssertFalse(core.resolution.isRetrying)
        XCTAssertTrue(core.resolution.lastMessage.contains("중단"))
    }

    func testRetryRereadsOptions() {
        display.options = [FakeDisplay.hd]   // 목표가 아직 없는 상태 (잠금 화면 등)
        vnc.clients = ["10.0.0.2"]
        let core = makeCore()
        core.tick()
        XCTAssertEqual(core.resolution.options, [FakeDisplay.hd])

        display.options = [FakeDisplay.hd, FakeDisplay.small]
        clock.advance(by: core.resolution.retryInterval)
        core.tick()

        XCTAssertEqual(core.resolution.options, display.options)
        XCTAssertEqual(core.resolution.currentID, FakeDisplay.small.id)
    }

    func testRetryStopsWhenSessionEnds() {
        display.applySucceeds = false
        vnc.clients = ["10.0.0.2"]
        let core = makeCore()
        core.tick()
        vnc.clients = []
        core.tick()
        core.tick()
        let count = display.applied.count

        display.applySucceeds = true
        clock.advance(by: 100)
        core.tick()
        XCTAssertFalse(display.applied.dropFirst(count).contains(FakeDisplay.small.id))
    }

    func testRestoreFailureKeepsOriginalAndRetries() {
        vnc.clients = ["10.0.0.2"]
        let core = makeCore()
        core.tick()
        display.applySucceeds = false
        vnc.clients = []
        core.tick()
        core.tick()

        XCTAssertEqual(settings.originalResolutionID, FakeDisplay.hd.id)
        XCTAssertTrue(core.resolution.lastMessage.hasPrefix("복원 실패"))

        display.applySucceeds = true
        clock.advance(by: core.resolution.retryInterval)
        core.tick()
        XCTAssertNil(settings.originalResolutionID)
        XCTAssertEqual(core.resolution.currentID, FakeDisplay.hd.id)
    }

    func testCustomRetryConstantsAreInjectable() {
        display.applySucceeds = false
        vnc.clients = ["10.0.0.2"]
        let resolution = ResolutionController(display: display, settings: settings, clock: clock,
                                              retryInterval: 1, maxRetryAttempts: 2)
        resolution.handle(clients: vnc.clients)
        for _ in 0..<5 {
            clock.advance(by: 1)
            resolution.handle(clients: vnc.clients)
        }
        XCTAssertEqual(display.applied.count, 3)
    }

    // MARK: 디스플레이 변경·해상도 목록

    func testDisplayConfigurationChangeRefreshesOptions() {
        let core = makeCore()
        display.options = [FakeDisplay.hd]
        display.current = FakeDisplay.hd
        core.resolution.displayConfigurationChanged()
        XCTAssertEqual(core.resolution.options, [FakeDisplay.hd])
    }

    func testFewOptionsFlag() {
        display.options = [FakeDisplay.hd, FakeDisplay.small]
        XCTAssertTrue(makeCore().resolution.hasFewOptions)

        display.options = (0..<ResolutionController.fewOptionsThreshold).map {
            ResolutionOption(width: 1000 + $0, height: 600, pixelWidth: 1000 + $0, pixelHeight: 600)
        }
        XCTAssertFalse(makeCore().resolution.hasFewOptions)
    }

    // MARK: 지금 적용

    func testApplyNowFailureIsReported() {
        display.applySucceeds = false
        let core = makeCore()
        core.resolution.applyTargetNow()
        XCTAssertTrue(core.resolution.lastMessage.hasPrefix("해상도 변경 실패"))
        XCTAssertTrue(core.resolution.hasOriginal)
    }
}
