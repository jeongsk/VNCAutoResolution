import CryptoKit
import Foundation
import Network
import Security

/// 페어링 암호 -> TLS-PSK 설정. (Apple TicTacToe 샘플 방식)
/// 암호가 다르면 PSK가 달라 TLS 핸드셰이크가 실패한다.
enum PairingKey {
    private static let context = Data("VNCAutoResolution pairing key v1".utf8)
    /// PSK identity 힌트. 비밀이 아니다.
    private static let identity = Data("VNCAutoResolution".utf8)

    /// 페어링 암호에서 32바이트 대칭 키를 파생한다: HMAC-SHA256(key: 암호, message: 고정 문맥 문자열).
    static func derive(passphrase: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: context, using: SymmetricKey(data: Data(passphrase.utf8)))
        return Data(mac)
    }

    static func tlsOptions(passphrase: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        let key = derive(passphrase: passphrase).withUnsafeBytes { DispatchData(bytes: $0) }
        let hint = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, key as __DispatchData, hint as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        return options
    }
}
