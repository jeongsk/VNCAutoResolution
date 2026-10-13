/// 클립보드 내용 한 번 읽은 것: 일반 텍스트(없으면 nil)와 그 항목의 타입 식별자 목록.
public struct ClipboardItem: Equatable, Sendable {
    public let text: String?
    public let types: [String]
    public init(text: String?, types: [String]) {
        self.text = text
        self.types = types
    }
}

/// 클립보드 포트: 변경 횟수를 읽고, 내용을 읽고, 일반 텍스트를 쓴다.
/// 실제 구현은 일반 클립보드(`NSPasteboard.general`)이고, 코어가 `changeCount`를 폴링한다.
public protocol ClipboardAccessing: AnyObject {
    /// 내용이 바뀔 때마다 오르는 값. 쓰기 후에도 오른다.
    var changeCount: Int { get }
    /// 지금 클립보드의 첫 항목.
    func read() -> ClipboardItem
    /// 클립보드를 이 일반 텍스트로 바꾼다.
    func write(text: String)
}

/// 클립보드 포트를 주입하지 않은 코어용: 아무것도 하지 않는다.
final class NullClipboard: ClipboardAccessing {
    var changeCount: Int { 0 }
    func read() -> ClipboardItem { ClipboardItem(text: nil, types: []) }
    func write(text: String) {}
}
