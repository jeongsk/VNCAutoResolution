/// VNC 감지 포트: 현재 들어와 있는 VNC 클라이언트 주소 목록을 돌려준다.
/// 실제 구현은 외부 프로세스를 실행할 수 있어 블로킹이므로 백그라운드에서 호출할 수 있게 Sendable로 둔다.
public protocol VNCDetecting: Sendable {
    func activeClients() -> [String]
}
