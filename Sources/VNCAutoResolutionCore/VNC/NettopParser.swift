/// `nettop -m tcp -L 1 -n -J state` 출력에서 VNC 클라이언트를 골라내는 순수 파서.
/// macOS 27부터 netstat이 TCP 소켓을 보여 주지 않아 이 출력을 기본으로 쓴다.
public enum NettopParser {
    /// 로컬 포트가 5900이고 Established인 줄(들어오는 연결)만 클라이언트로 본다.
    /// 예: "tcp4 192.168.0.10:5900<->192.168.0.5:54321,Established,"
    ///     "tcp6 fe80::1.5900<->fe80::2.54321,Established,"
    public static func parse(_ output: String) -> [String] {
        var clients: [String] = []
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("tcp4 ") || line.hasPrefix("tcp6 ") else { continue }
            let fields = line.dropFirst(5).split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[1] == "Established" else { continue }
            let ends = fields[0].components(separatedBy: "<->")
            guard ends.count == 2,
                  let local = split(ends[0]), local.port == String(NetstatParser.vncPort),
                  let remote = split(ends[1]) else { continue }
            if !clients.contains(remote.host) { clients.append(remote.host) }
        }
        return clients
    }

    /// "주소:포트"(IPv4) 또는 "주소.포트"(IPv6)를 나눈다. 포트는 마지막 구분자 뒤다.
    private static func split(_ endpoint: String) -> (host: String, port: String)? {
        guard let i = endpoint.lastIndex(where: { $0 == ":" || $0 == "." }) else { return nil }
        return (String(endpoint[..<i]), String(endpoint[endpoint.index(after: i)...]))
    }
}
