import Foundation
import VNCAutoResolutionCore

/// 가상 디스플레이 설정 저장소 포트의 실제 구현: UserDefaults.
/// "클라이언트 화면에 맞추기"는 값이 없으면 true, "HiDPI 가상 디스플레이"는 값이 없으면 false.
final class UserDefaultsVirtualDisplaySettings: VirtualDisplaySettingsStoring {
    private let defaults: UserDefaults

    private enum Keys {
        static let fitToClient = "fitToClientEnabled"
        static let hiDPI = "virtualDisplayHiDPI"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var fitToClientEnabled: Bool {
        get { defaults.object(forKey: Keys.fitToClient) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.fitToClient) }
    }

    var virtualDisplayHiDPI: Bool {
        get { defaults.object(forKey: Keys.hiDPI) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.hiDPI) }
    }
}
