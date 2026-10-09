import Foundation
import VNCAutoResolutionCore

/// 설정 저장소 포트의 실제 구현: UserDefaults. (키 이름은 기존 버전과 동일해 설정이 유지된다.)
final class UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "enabled"
        static let target = "targetResolution"
        static let original = "originalResolution"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var autoChangeEnabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    var targetResolutionID: String {
        get { defaults.string(forKey: Keys.target) ?? "" }
        set { defaults.set(newValue, forKey: Keys.target) }
    }

    var originalResolutionID: String? {
        get { defaults.string(forKey: Keys.original) }
        set { defaults.set(newValue, forKey: Keys.original) }
    }
}
