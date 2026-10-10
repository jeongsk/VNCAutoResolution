import XCTest
@testable import VNCAutoResolutionCore

/// 가상 디스플레이 컨트롤러와 해상도 컨트롤러의 상호 배제 (가짜 포트 + FakeClock).
final class VirtualDisplayTests: XCTestCase {
    private var vnc: FakeVNCDetector!
    private var display: FakeDisplay!
    private var settings: FakeSettingsStore!
    private var vdPort: FakeVirtualDisplay!
    private var vdSettings: InMemoryVirtualDisplaySettings!
    private var transport: FakePeerTransport!
    private var clock: FakeClock!
    private var core: AppCore!

    private let peerID = "aaa"

    override func setUp() {
        vnc = FakeVNCDetector()
        display = FakeDisplay()
        settings = FakeSettingsStore()
        settings.targetResolutionID = FakeDisplay.small.id
        vdPort = FakeVirtualDisplay()
        vdSettings = InMemoryVirtualDisplaySettings()
        transport = FakePeerTransport()
        clock = FakeClock()
        core = AppCore(
            vnc: vnc, display: display, settings: settings, clock: clock,
            peerTransport: transport, peerSettings: InMemoryPeerStores(deviceID: "mmm"),
            inputSource: FakeInputSource(), viewerApps: FakeViewerApps(), screen: FakeScreen(),
            virtualDisplay: vdPort, virtualDisplaySettings: vdSettings)
        connectPeer()
    }

    // MARK: 도우미

    private func connectPeer() {
        core.peers.handle(.connected(1, route: .manual, isOutbound: true))
        core.peers.handle(.received(1, PeerCodec.encode(
            .hello(deviceID: peerID, name: "상대", protocolVersion: 1, route: nil))))
    }

    /// 클라이언트가 세션 신호와 화면 크기를 보낸 것처럼 만든다.
    private func clientReports(_ w: Int = 1512, _ h: Int = 982, _ scale: Double = 2) {
        core.peers.handle(.received(1, PeerCodec.encode(.session(deviceID: peerID, active: true))))
        core.peers.handle(.received(1, PeerCodec.encode(.display(deviceID: peerID, width: w, height: h, scale: scale))))
    }

    private func clientSessionEnds() {
        core.peers.handle(.received(1, PeerCodec.encode(.session(deviceID: peerID, active: false))))
    }

    private func vncConnect() { vnc.clients = ["192.168.0.5"]; core.tick() }
    private func vncDisconnect() { vnc.clients = []; core.tick(); core.tick() }

    private let mode1512 = VirtualDisplayMode(width: 1512, height: 982, hiDPI: false)

    // MARK: 생성 조건

    func testCreatesWhenAllConditionsMetClientInfoFirst() {
        clientReports()
        vncConnect()
        XCTAssertEqual(vdPort.created, [mode1512])
        XCTAssertEqual(core.virtualDisplay.status, .active(width: 1512, height: 982))
        XCTAssertTrue(core.virtualDisplay.isActive)
    }

    func testCreatesWhenClientInfoArrivesAfterSessionStart() {
        vncConnect()
        XCTAssertTrue(vdPort.created.isEmpty)
        clientReports()
        XCTAssertEqual(vdPort.created, [mode1512])
    }

    func testNoCreationWithoutSession() {
        clientReports()
        core.tick()
        XCTAssertTrue(vdPort.created.isEmpty)
        XCTAssertEqual(core.virtualDisplay.status, .standby)
    }

    func testNoCreationWithoutClientInfo() {
        vncConnect()
        core.tick()
        XCTAssertTrue(vdPort.created.isEmpty)
        XCTAssertEqual(core.virtualDisplay.status, .standby)
    }

    func testNoCreationWhenFeatureOff() {
        vdSettings.fitToClientEnabled = false
        clientReports()
        vncConnect()
        XCTAssertTrue(vdPort.created.isEmpty)
    }

    func testNoCreationWhenUnavailable() {
        vdPort.isAvailable = false
        clientReports()
        vncConnect()
        XCTAssertTrue(vdPort.created.isEmpty)
        XCTAssertEqual(core.virtualDisplay.status, .unavailable)
    }

    func testNoCreationWhenHighPerformanceDisplayExists() {
        vdPort.hasHighPerformanceDisplay = true
        clientReports()
        vncConnect()
        XCTAssertTrue(vdPort.created.isEmpty)
        XCTAssertEqual(core.virtualDisplay.status, .standby)
        // 가상 디스플레이를 못 만들면 기존 목표 해상도 경로로 동작한다.
        XCTAssertEqual(display.applied, [FakeDisplay.small.id])
    }

    func testHighPerformanceDisplayAppearingLaterDoesNotRemoveOurs() {
        clientReports()
        vncConnect()
        vdPort.hasHighPerformanceDisplay = true
        core.tick()
        XCTAssertTrue(core.virtualDisplay.isActive)
        XCTAssertEqual(vdPort.removeCount, 0)
    }

    func testUnavailablePortNeverBreaksResolutionPath() {
        vdPort.isAvailable = false
        clientReports()
        vncConnect()
        XCTAssertEqual(display.applied, [FakeDisplay.small.id])
    }

    // MARK: 제거 (디바운스)

    func testRemovedAfterTwoConsecutiveEmptyPolls() {
        clientReports()
        vncConnect()
        vnc.clients = []
        core.tick()
        XCTAssertTrue(core.virtualDisplay.isActive, "한 번 비었다고 지우지 않는다")
        core.tick()
        XCTAssertFalse(core.virtualDisplay.isActive)
        XCTAssertEqual(vdPort.removeCount, 1)
        XCTAssertEqual(core.virtualDisplay.status, .standby)
    }

    func testSingleEmptyPollKeepsDisplay() {
        clientReports()
        vncConnect()
        vnc.clients = []
        core.tick()
        vnc.clients = ["192.168.0.5"]
        core.tick()
        core.tick()
        XCTAssertEqual(vdPort.removeCount, 0)
        XCTAssertEqual(vdPort.created.count, 1)
    }

    func testReconnectCreatesAgain() {
        clientReports()
        vncConnect()
        vncDisconnect()
        XCTAssertFalse(core.virtualDisplay.isActive)
        clientReports()   // 새 세션: 클라이언트가 다시 화면 정보를 보낸다.
        vncConnect()
        XCTAssertEqual(vdPort.created.count, 2)
    }

    // MARK: 모드 변경과 HiDPI 계산

    func testClientInfoChangeUpdatesMode() {
        clientReports()
        vncConnect()
        clientReports(1728, 1117, 2)
        XCTAssertEqual(vdPort.updated, [VirtualDisplayMode(width: 1728, height: 1117, hiDPI: false)])
        XCTAssertEqual(vdPort.created.count, 1)
        XCTAssertEqual(core.virtualDisplay.status, .active(width: 1728, height: 1117))
    }

    func testUpdateFailureRecreatesDisplay() {
        clientReports()
        vncConnect()
        vdPort.updateSucceeds = false
        clientReports(1728, 1117, 2)
        XCTAssertEqual(vdPort.removeCount, 1)
        XCTAssertEqual(vdPort.created.last, VirtualDisplayMode(width: 1728, height: 1117, hiDPI: false))
        XCTAssertTrue(core.virtualDisplay.isActive)
    }

    func testOneXUsesPointSizeAsIs() {
        XCTAssertEqual(
            VirtualDisplayMode(client: ClientDisplay(deviceID: "a", width: 1512, height: 982, scale: 2), hiDPI: false),
            VirtualDisplayMode(width: 1512, height: 982, hiDPI: false))
    }

    func testHiDPIDoublesPointSize() {
        let mode = VirtualDisplayMode(client: ClientDisplay(deviceID: "a", width: 1512, height: 982, scale: 2), hiDPI: true)
        XCTAssertEqual(mode, VirtualDisplayMode(width: 3024, height: 1964, hiDPI: true))
        XCTAssertEqual(mode.pointSize.width, 1512)
        XCTAssertEqual(mode.pointSize.height, 982)
        let triple = VirtualDisplayMode(client: ClientDisplay(deviceID: "a", width: 800, height: 600, scale: 3), hiDPI: true)
        XCTAssertEqual(triple, VirtualDisplayMode(width: 1600, height: 1200, hiDPI: true))
    }

    func testHiDPIOnOneXClientStaysOneX() {
        let mode = VirtualDisplayMode(client: ClientDisplay(deviceID: "a", width: 1920, height: 1080, scale: 1), hiDPI: true)
        XCTAssertEqual(mode, VirtualDisplayMode(width: 1920, height: 1080, hiDPI: false))
    }

    func testCreatedWithHiDPIWhenSettingOn() {
        vdSettings.virtualDisplayHiDPI = true
        clientReports()
        vncConnect()
        XCTAssertEqual(vdPort.created, [VirtualDisplayMode(width: 3024, height: 1964, hiDPI: true)])
        XCTAssertEqual(core.virtualDisplay.status, .active(width: 1512, height: 982))
    }

    func testTogglingHiDPIMidSessionRecreatesDisplay() {
        clientReports()
        vncConnect()
        core.virtualDisplay.hiDPI = true
        XCTAssertEqual(vdPort.updated, [])
        XCTAssertEqual(vdPort.removeCount, 1)
        XCTAssertEqual(vdPort.created.last, VirtualDisplayMode(width: 3024, height: 1964, hiDPI: true))
        XCTAssertEqual(core.virtualDisplay.status, .active(width: 1512, height: 982))
        XCTAssertTrue(vdSettings.virtualDisplayHiDPI)

        core.virtualDisplay.hiDPI = false
        XCTAssertEqual(vdPort.removeCount, 2)
        XCTAssertEqual(vdPort.created.last, VirtualDisplayMode(width: 1512, height: 982, hiDPI: false))
    }

    // MARK: 설정

    func testDefaults() {
        XCTAssertTrue(vdSettings.fitToClientEnabled)
        XCTAssertFalse(vdSettings.virtualDisplayHiDPI)
    }

    func testTurningFeatureOffMidSessionRemovesAndFallsBackToTarget() {
        clientReports()
        vncConnect()
        XCTAssertTrue(display.applied.isEmpty)
        core.virtualDisplay.fitToClient = false
        XCTAssertFalse(core.virtualDisplay.isActive)
        XCTAssertEqual(display.applied, [FakeDisplay.small.id], "세션이 이어지는 중이면 목표 해상도로 대체한다")
        XCTAssertEqual(settings.originalResolutionID, FakeDisplay.hd.id)
    }

    func testTurningFeatureOnMidSessionTakesOverFromTarget() {
        vdSettings.fitToClientEnabled = false
        clientReports()
        vncConnect()
        XCTAssertEqual(display.current, FakeDisplay.small)
        core.virtualDisplay.fitToClient = true
        XCTAssertTrue(core.virtualDisplay.isActive)
        XCTAssertEqual(display.applied, [FakeDisplay.small.id, FakeDisplay.hd.id])
        XCTAssertNil(settings.originalResolutionID)
    }

    // MARK: 해상도 컨트롤러와 상호 배제

    func testSessionStartWithClientInfoSkipsTargetResolution() {
        clientReports()
        vncConnect()
        XCTAssertTrue(display.applied.isEmpty)
        XCTAssertNil(settings.originalResolutionID)
    }

    func testSessionStartWithoutClientInfoUsesTargetResolution() {
        vncConnect()
        XCTAssertEqual(display.applied, [FakeDisplay.small.id])
        XCTAssertFalse(core.virtualDisplay.isActive)
    }

    func testClientInfoArrivingAfterTargetAppliedRestoresThenCreates() {
        vncConnect()
        XCTAssertEqual(display.applied, [FakeDisplay.small.id])
        clientReports()
        XCTAssertEqual(display.applied, [FakeDisplay.small.id, FakeDisplay.hd.id], "원래 해상도 복원 후 가상 디스플레이")
        XCTAssertNil(settings.originalResolutionID)
        XCTAssertEqual(vdPort.created, [mode1512])
    }

    func testResolutionControllerDoesNothingWhileVirtualDisplayExists() {
        clientReports()
        vncConnect()
        // 사용자 조작·디스플레이 변경·폴링 어느 것도 해상도를 바꾸지 않는다.
        core.resolution.applyTargetNow()
        core.resolution.restoreOriginal()
        core.resolution.displayConfigurationChanged()
        for _ in 0..<5 { clock.advance(by: 30); core.tick() }
        XCTAssertTrue(display.applied.isEmpty)
    }

    func testDisconnectDoesNotRestoreResolutionBecauseNothingWasApplied() {
        clientReports()
        vncConnect()
        vncDisconnect()
        XCTAssertTrue(display.applied.isEmpty)
        XCTAssertFalse(core.virtualDisplay.isActive)
    }

    func testPendingRetryIsDroppedWhenVirtualDisplayTakesOver() {
        display.applySucceeds = false
        vncConnect()
        XCTAssertTrue(core.resolution.isRetrying)
        display.applySucceeds = true
        clientReports()
        XCTAssertFalse(core.resolution.isRetrying)
        let appliedBefore = display.applied.count
        for _ in 0..<5 { clock.advance(by: 30); core.tick() }
        XCTAssertEqual(display.applied.count, appliedBefore, "재시도하지 않는다")
    }

    func testRestoreFailureOnTakeoverStillCreatesAndRestoresAfterSessionEnds() {
        vncConnect()                       // 목표 적용, 원래 해상도 저장
        display.applySucceeds = false
        clientReports()                    // 복원 실패해도 가상 디스플레이는 만든다
        XCTAssertTrue(core.virtualDisplay.isActive)
        XCTAssertNotNil(settings.originalResolutionID)
        display.applySucceeds = true
        vncDisconnect()                    // 제거 후 화면 구성이 자리 잡으면 남은 원래 해상도를 복원
        XCTAssertFalse(core.virtualDisplay.isActive)
        clock.advance(by: 3); core.tick()
        XCTAssertEqual(display.current, FakeDisplay.hd)
        XCTAssertNil(settings.originalResolutionID)
    }

    /// 가상 디스플레이를 떼면 macOS가 화면 구성을 바꾸며 해상도를 덮어쓴다. 바로 복원하지 않고 잠시 뒤에 한다.
    func testRestoreAfterVirtualDisplayRemovalWaitsForDisplaysToSettle() {
        vncConnect()
        display.applySucceeds = false
        clientReports()
        display.applySucceeds = true
        let appliedBefore = display.applied.count
        vncDisconnect()
        XCTAssertFalse(core.virtualDisplay.isActive)
        XCTAssertEqual(display.applied.count, appliedBefore, "제거 직후에는 바꾸지 않는다")
        XCTAssertNotNil(settings.originalResolutionID)
        clock.advance(by: 1); core.tick()
        XCTAssertEqual(display.applied.count, appliedBefore)
        clock.advance(by: 2); core.tick()
        XCTAssertEqual(display.current, FakeDisplay.hd)
        XCTAssertNil(settings.originalResolutionID)
        XCTAssertEqual(core.resolution.lastMessage, "접속 해제 → 원래 해상도 복원")
    }

    // MARK: 클라이언트 화면 정보가 사라질 때

    func testClientInfoClearedMidSessionKeepsLastModeUntilSessionEnds() {
        clientReports()
        vncConnect()
        clientSessionEnds()
        XCTAssertNil(core.clientDisplay)
        XCTAssertTrue(core.virtualDisplay.isActive, "정보만 사라져도 세션이 이어지면 유지한다")
        XCTAssertEqual(vdPort.removeCount, 0)
        XCTAssertTrue(display.applied.isEmpty)
        vncDisconnect()
        XCTAssertFalse(core.virtualDisplay.isActive)
        XCTAssertTrue(display.applied.isEmpty, "깜빡임 없이 한 번에 정리된다")
    }

    // MARK: 생성 실패 재시도

    func testCreateFailureRetriesWithInterval() {
        vdPort.createSucceeds = false
        clientReports()
        vncConnect()
        XCTAssertEqual(vdPort.created.count, 1)
        XCTAssertFalse(core.virtualDisplay.isActive)
        core.tick()
        XCTAssertEqual(vdPort.created.count, 1, "간격 전에는 다시 시도하지 않는다")
        clock.advance(by: core.virtualDisplay.retryInterval)
        vdPort.createSucceeds = true
        core.tick()
        XCTAssertTrue(core.virtualDisplay.isActive)
        XCTAssertEqual(vdPort.created.count, 2)
    }

    func testCreateFailureStopsAfterMaxAttempts() {
        vdPort.createSucceeds = false
        clientReports()
        vncConnect()
        for _ in 0..<10 { clock.advance(by: core.virtualDisplay.retryInterval); core.tick() }
        XCTAssertEqual(vdPort.created.count, core.virtualDisplay.maxAttempts)
    }

    // MARK: 실제 화면 모드로 맞추기 (#13)

    private static let monitorHiDPI = ResolutionOption(width: 1504, height: 846, pixelWidth: 3008, pixelHeight: 1692)
    private static let monitorOneX = ResolutionOption(width: 1440, height: 900, pixelWidth: 1440, pixelHeight: 900)
    private static let monitorBigHiDPI = ResolutionOption(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160)
    private static let monitorTiny = ResolutionOption(width: 1024, height: 576, pixelWidth: 2048, pixelHeight: 1152)

    /// 4K 모니터처럼 해상도가 많은 화면.
    private func useMonitor() {
        display.options = [Self.monitorBigHiDPI, FakeDisplay.hd, Self.monitorHiDPI, Self.monitorOneX, Self.monitorTiny]
        display.current = Self.monitorBigHiDPI
        core.resolution.refreshDisplay()
    }

    func testMonitorWithFittingModeUsesItInsteadOfVirtualDisplay() {
        useMonitor()
        vdSettings.virtualDisplayHiDPI = true
        clientReports()
        vncConnect()
        XCTAssertEqual(vdPort.created, [])
        XCTAssertEqual(display.current, Self.monitorHiDPI)
        XCTAssertEqual(settings.originalResolutionID, Self.monitorBigHiDPI.id)
    }

    func testMonitorOneXPicksLargestFittingOneXMode() {
        useMonitor()
        clientReports()
        vncConnect()
        XCTAssertEqual(vdPort.created, [])
        XCTAssertEqual(display.current, Self.monitorOneX)
    }

    func testMonitorModeRestoredOnDisconnect() {
        useMonitor()
        vdSettings.virtualDisplayHiDPI = true
        clientReports()
        vncConnect()
        vncDisconnect()
        XCTAssertEqual(display.current, Self.monitorBigHiDPI)
        XCTAssertNil(settings.originalResolutionID)
    }

    func testClientInfoArrivingAfterSessionStartAppliesMonitorMode() {
        useMonitor()
        settings.autoChangeEnabled = false
        vncConnect()
        XCTAssertEqual(display.current, Self.monitorBigHiDPI)
        clientReports()
        XCTAssertEqual(display.current, Self.monitorOneX)
        XCTAssertEqual(vdPort.created, [])
    }

    func testTogglingHiDPIOnMonitorSwitchesMode() {
        useMonitor()
        settings.autoChangeEnabled = false
        clientReports()
        vncConnect()
        core.virtualDisplay.hiDPI = true
        XCTAssertEqual(display.current, Self.monitorHiDPI)
        core.virtualDisplay.fitToClient = false   // 맞출 것도 목표 해상도도 없으면 원래대로.
        XCTAssertEqual(vdPort.created, [])
        XCTAssertEqual(display.current, Self.monitorBigHiDPI)
        XCTAssertNil(settings.originalResolutionID)
    }

    func testNoFittingMonitorModeFallsBackToVirtualDisplay() {
        useMonitor()
        clientReports(800, 600, 2)   // 들어가는 모드가 없거나 너무 작다.
        vncConnect()
        XCTAssertEqual(vdPort.created.count, 1)
    }

    func testMatcherIgnoresDisplaysWithFewModes() {
        let client = ClientDisplay(deviceID: "a", width: 1512, height: 982, scale: 2)
        XCTAssertNil(ClientModeMatcher.bestOption(for: client, hiDPI: true, in: [FakeDisplay.retina]))
        XCTAssertEqual(
            ClientModeMatcher.bestOption(
                for: client, hiDPI: true,
                in: [Self.monitorBigHiDPI, Self.monitorHiDPI, Self.monitorOneX, Self.monitorTiny, FakeDisplay.retina]),
            FakeDisplay.retina)   // 1440×900이 1504×846보다 넓다.
    }

    func testMonitorModeKeptWhileClientInfoBrieflyDisappears() {
        useMonitor()
        vdSettings.virtualDisplayHiDPI = true
        clientReports()
        vncConnect()
        clientSessionEnds()   // 피어 재연결 등으로 화면 정보가 잠깐 사라진다.
        XCTAssertEqual(display.current, Self.monitorHiDPI)
        XCTAssertEqual(display.applied, [Self.monitorHiDPI.id])
        clientReports()
        XCTAssertEqual(display.applied, [Self.monitorHiDPI.id])
        vncDisconnect()
        XCTAssertEqual(display.current, Self.monitorBigHiDPI)
    }

    // MARK: 남은 가상 디스플레이 (#13)

    func testLeftoverCountIsReportedFromPort() {
        XCTAssertEqual(core.virtualDisplay.leftoverCount, 0)
        vdPort.leftoverCount = 2
        XCTAssertEqual(core.virtualDisplay.leftoverCount, 2)
    }

    func testLeftoverCountIsZeroWhenUnavailable() {
        vdPort.leftoverCount = 2
        vdPort.isAvailable = false
        XCTAssertEqual(core.virtualDisplay.leftoverCount, 0)
    }
}
