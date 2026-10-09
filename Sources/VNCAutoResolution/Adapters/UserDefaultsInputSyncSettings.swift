import Foundation
import VNCAutoResolutionCore

/// 입력 동기화 설정 저장소 포트의 실제 구현: UserDefaults. 값이 없으면 기본값 true.
final class UserDefaultsInputSyncSettings: InputSyncSettingsStoring {
    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "inputSyncEnabled"
        static let onlyDuringRemote = "inputSyncOnlyDuringRemote"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var inputSyncEnabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    var inputSyncOnlyDuringRemote: Bool {
        get { defaults.object(forKey: Keys.onlyDuringRemote) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.onlyDuringRemote) }
    }
}
