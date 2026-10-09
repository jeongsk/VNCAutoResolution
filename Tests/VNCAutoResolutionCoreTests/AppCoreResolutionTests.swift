import XCTest
@testable import VNCAutoResolutionCore

final class AppCoreResolutionTests: XCTestCase {
    private var vnc: FakeVNCDetector!
    private var display: FakeDisplay!
    private var settings: FakeSettingsStore!
    private var clock: FakeClock!
    private var core: AppCore!

    override func setUp() {
        vnc = FakeVNCDetector()
        display = FakeDisplay()
        settings = FakeSettingsStore()
        clock = FakeClock()
        settings.targetResolutionID = FakeDisplay.small.id
        core = AppCore(vnc: vnc, display: display, settings: settings, clock: clock)
    }

    func testClientAppearingSavesOriginalAndAppliesTarget() {
        vnc.clients = ["10.0.0.2"]
        core.tick()

        XCTAssertEqual(settings.originalResolutionID, FakeDisplay.hd.id)
        XCTAssertEqual(display.applied, [FakeDisplay.small.id])
        XCTAssertEqual(core.resolution.currentID, FakeDisplay.small.id)
        XCTAssertTrue(core.resolution.isConnected)
    }

    func testClientDisappearingRestoresOriginal() {
        vnc.clients = ["10.0.0.2"]
        core.tick()
        vnc.clients = []
        core.tick()
        core.tick()

        XCTAssertEqual(display.applied, [FakeDisplay.small.id, FakeDisplay.hd.id])
        XCTAssertNil(settings.originalResolutionID)
        XCTAssertFalse(core.resolution.isConnected)
    }

    func testSingleEmptyPollDoesNotRestore() {
        vnc.clients = ["10.0.0.2"]
        core.tick()
        vnc.clients = []
        core.tick()
        vnc.clients = ["10.0.0.2"]
        core.tick()

        XCTAssertEqual(display.applied, [FakeDisplay.small.id])
        XCTAssertTrue(core.resolution.isConnected)
    }

    func testDisabledAutoChangeIssuesNoCommands() {
        settings.autoChangeEnabled = false
        vnc.clients = ["10.0.0.2"]
        core.tick()
        vnc.clients = []
        core.tick()
        core.tick()

        XCTAssertEqual(display.applied, [])
        XCTAssertNil(settings.originalResolutionID)
    }

    func testNoTargetIssuesNoCommands() {
        settings.targetResolutionID = ""
        vnc.clients = ["10.0.0.2"]
        core.tick()
        vnc.clients = []
        core.tick()
        core.tick()

        XCTAssertEqual(display.applied, [])
    }

    func testRestoreWaitsForLastOfMultipleClients() {
        vnc.clients = ["10.0.0.2", "10.0.0.3"]
        core.tick()
        vnc.clients = ["10.0.0.3"]
        core.tick()
        core.tick()
        XCTAssertEqual(display.applied, [FakeDisplay.small.id])

        vnc.clients = []
        core.tick()
        core.tick()
        XCTAssertEqual(display.applied, [FakeDisplay.small.id, FakeDisplay.hd.id])
    }

    func testApplyFailureIsReportedWithTimestamp() {
        display.applySucceeds = false
        vnc.clients = ["10.0.0.2"]
        core.tick()

        XCTAssertEqual(core.resolution.lastMessage, "해상도 변경 실패")
        XCTAssertEqual(core.resolution.lastMessageAt, clock.now)
    }

    func testApplyNowSavesOriginalSoRestoreIsPossible() {
        core.resolution.applyTargetNow()
        XCTAssertTrue(core.resolution.hasOriginal)

        core.resolution.restoreOriginal()
        XCTAssertEqual(display.applied, [FakeDisplay.small.id, FakeDisplay.hd.id])
        XCTAssertFalse(core.resolution.hasOriginal)
    }

    func testRestoreWithoutOriginalDoesNothing() {
        core.resolution.restoreOriginal()
        XCTAssertEqual(display.applied, [])
    }

    func testApplyNowWithoutTargetDoesNothing() {
        settings.targetResolutionID = ""
        core.resolution.applyTargetNow()
        XCTAssertEqual(display.applied, [])
    }

    func testOptionsAreLoadedFromDisplayPort() {
        XCTAssertEqual(core.resolution.options, display.options)
        XCTAssertEqual(core.resolution.currentID, FakeDisplay.hd.id)
    }
}
