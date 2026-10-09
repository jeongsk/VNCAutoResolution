import Carbon
import Foundation
import os
import VNCAutoResolutionCore

/// 입력 소스 포트의 실제 구현: Carbon TIS. (조회·언어 판정은 HangulSync에서 옮김 — THIRD_PARTY_NOTICES.md 참고)
/// 변경 알림은 `onChange`로 전달한다 (TIS 분산 알림, 메인 큐).
final class CarbonInputSource: InputSourcing {
    /// 로컬 입력 소스가 바뀌었을 때 불린다.
    var onChange: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var lastSelect: Date?
    private static let log = Logger(subsystem: "com.jeongsk.VNCAutoResolution", category: "inputsync")

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let since = self.lastSelect.map { String(format: "%.0f", Date().timeIntervalSince($0) * 1000) } ?? "-"
            Self.log.debug("TIS 알림: 읽은 값 \(self.current?.id ?? "nil", privacy: .public), 마지막 자체 선택 후 \(since, privacy: .public)ms")
            self.onChange?()
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    var current: InputState? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.state(of: source)
    }

    var available: [InputState] {
        Self.selectableSources().compactMap(Self.state(of:))
    }

    func select(id: String) -> Bool {
        guard let source = Self.selectableSources().first(where: { Self.stringProperty($0, kTISPropertyInputSourceID) == id })
        else { return false }
        lastSelect = Date()
        return TISSelectInputSource(source) == noErr
    }

    // MARK: TIS 도우미

    private static func state(of source: TISInputSource) -> InputState? {
        guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        return InputState(id: id, isKorean: isKorean(source))
    }

    /// 사용자 목록에 등록된, 선택 가능한 키보드 입력 소스.
    private static func selectableSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.filter { source in
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable),
                  CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()) else { return false }
            return stringProperty(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String)
        }
    }

    private static func isKorean(_ source: TISInputSource) -> Bool {
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as NSArray
            if languages.contains(where: { ($0 as? String)?.hasPrefix("ko") == true }) { return true }
        }
        // 구름입력기 등 언어 메타데이터가 없는 경우 ID로 추정한다.
        if let id = stringProperty(source, kTISPropertyInputSourceID)?.lowercased() {
            return id.contains("korean") || id.contains("hangul") || id.contains("gureum")
        }
        return false
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
