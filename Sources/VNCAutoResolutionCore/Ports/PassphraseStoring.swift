/// 페어링 암호 저장소 포트. 실제 구현은 Keychain.
public protocol PassphraseStoring: AnyObject {
    /// 저장된 페어링 암호. 없으면 nil. nil이나 빈 문자열을 쓰면 삭제한다.
    var passphrase: String? { get set }
}
