import VNCAutoResolutionCore

/// 테스트용 클립보드. 실제 일반 클립보드처럼 내용이 바뀔 때마다 `changeCount`가 오른다.
final class FakeClipboard: ClipboardAccessing {
    private(set) var changeCount = 0
    private(set) var item = ClipboardItem(text: nil, types: [])
    private(set) var written: [String] = []

    func read() -> ClipboardItem { item }

    func write(text: String) {
        written.append(text)
        set(ClipboardItem(text: text, types: ["public.utf8-plain-text"]))
    }

    /// 사용자(또는 다른 앱)가 복사함.
    func userCopies(_ text: String, types: [String] = ["public.utf8-plain-text"]) {
        set(ClipboardItem(text: text, types: types))
    }

    func userCopiesNonText() {
        set(ClipboardItem(text: nil, types: ["public.png"]))
    }

    private func set(_ new: ClipboardItem) {
        item = new
        changeCount += 1
    }
}
