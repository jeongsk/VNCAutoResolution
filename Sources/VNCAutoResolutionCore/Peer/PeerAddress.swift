import Foundation

/// 사용자가 입력한 피어 주소를 host/port로 나눈다.
/// 허용 형식: `host`, `host:port`, `[v6]`, `[v6]:port`, 괄호 없는 IPv6(포트 생략으로 간주).
public struct PeerAddress: Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public static func parse(_ text: String, defaultPort: UInt16 = PeerDefaults.port) -> PeerAddress? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let tail = s[s.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if tail.isEmpty { return PeerAddress(host: host, port: defaultPort) }
            guard tail.hasPrefix(":"), let port = parsePort(tail.dropFirst()) else { return nil }
            return PeerAddress(host: host, port: port)
        }

        let colons = s.filter { $0 == ":" }.count
        if colons == 0 { return PeerAddress(host: s, port: defaultPort) }
        if colons > 1 { return PeerAddress(host: s, port: defaultPort) } // 괄호 없는 IPv6
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = parsePort(parts[1]) else { return nil }
        return PeerAddress(host: String(parts[0]), port: port)
    }

    private static func parsePort<S: StringProtocol>(_ s: S) -> UInt16? {
        guard let value = UInt16(s), value > 0 else { return nil }
        return value
    }
}
