import Foundation
import Security
import VNCAutoResolutionCore

/// 페어링 암호 저장소 포트의 실제 구현: Keychain (일반 암호 항목).
final class KeychainPassphraseStore: PassphraseStoring {
    private let service = "com.jeongsk.VNCAutoResolution"
    private let account = "pairing-passphrase"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    var passphrase: String? {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(baseQuery as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var attributes = baseQuery
            attributes[kSecValueData as String] = Data(newValue.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status != errSecSuccess {
                NSLog("VNCAutoResolution: Keychain 저장 실패 (\(status))")
            }
        }
    }
}
