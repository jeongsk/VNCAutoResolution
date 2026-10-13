import Foundation
import VNCAutoResolutionCore

/// 클립보드 공유 설정 저장소 포트의 실제 구현: UserDefaults. 값이 없으면 기본값 false.
final class UserDefaultsClipboardSettings: ClipboardSettingsStoring {
    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "clipboardSyncEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var clipboardSyncEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }
}
