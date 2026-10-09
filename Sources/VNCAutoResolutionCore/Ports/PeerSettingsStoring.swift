/// 피어 연결 설정 저장소 포트. (암호는 `PassphraseStoring`에 따로 둔다.)
public protocol PeerSettingsStoring: AnyObject {
    /// 이 기기의 고유 ID. 처음 읽을 때 만들어 저장하고 이후 바뀌지 않는다.
    var deviceID: String { get }
    /// 직접 연결할 피어 주소 ("host" 또는 "host:port"). 빈 문자열이면 없음.
    var manualPeerAddress: String { get set }
}
