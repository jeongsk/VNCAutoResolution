import VNCAutoResolutionCore

/// 테스트용 VNC 감지 포트. `clients`를 바꿔서 폴링 결과를 조작한다.
final class FakeVNCDetector: VNCDetecting, @unchecked Sendable {
    var clients: [String] = []
    func activeClients() -> [String] { clients }
}
