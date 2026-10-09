import XCTest
@testable import VNCAutoResolutionCore

/// 메뉴의 "현재 해상도" 문구 (#10).
final class CurrentResolutionLabelTests: XCTestCase {
    private let options = [
        ResolutionOption(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080),
    ]

    func testVirtualDisplayActiveShowsVirtualSize() {
        let label = CurrentResolutionLabel.text(
            options: options, currentID: options[0].id, virtualDisplay: .active(width: 1512, height: 982))
        XCTAssertEqual(label, "1512 × 982 (가상 디스플레이)")
    }

    func testWithoutVirtualDisplayShowsCurrentOption() {
        for status: VirtualDisplayController.Status in [.standby, .unavailable] {
            let label = CurrentResolutionLabel.text(options: options, currentID: options[0].id, virtualDisplay: status)
            XCTAssertEqual(label, options[0].label)
        }
    }

    func testUnknownCurrentID() {
        XCTAssertEqual(CurrentResolutionLabel.text(options: options, currentID: "x", virtualDisplay: .standby), "x")
        XCTAssertEqual(CurrentResolutionLabel.text(options: options, currentID: nil, virtualDisplay: .standby), "알 수 없음")
    }
}
