import AppKit
import VNCAutoResolutionCore

/// 클립보드 포트의 실제 구현: 일반 클립보드(`NSPasteboard.general`). 메인 스레드에서 쓴다.
final class GeneralPasteboard: ClipboardAccessing {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func read() -> ClipboardItem {
        // 숨김 표시는 항목 타입으로 붙으므로 모든 타입을 넘긴다.
        ClipboardItem(
            text: pasteboard.string(forType: .string),
            types: pasteboard.types?.map(\.rawValue) ?? [])
    }

    func write(text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
