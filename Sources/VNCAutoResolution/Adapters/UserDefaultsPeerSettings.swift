import Foundation
import VNCAutoResolutionCore

/// 피어 설정 저장소 포트의 실제 구현: UserDefaults. (암호는 Keychain)
final class UserDefaultsPeerSettings: PeerSettingsStoring {
    private let defaults: UserDefaults

    private enum Keys {
        static let deviceID = "peerDeviceID"
        static let manualAddress = "peerManualAddress"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var deviceID: String {
        if let id = defaults.string(forKey: Keys.deviceID) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Keys.deviceID)
        return id
    }

    var manualPeerAddress: String {
        get { defaults.string(forKey: Keys.manualAddress) ?? "" }
        set { defaults.set(newValue, forKey: Keys.manualAddress) }
    }
}
