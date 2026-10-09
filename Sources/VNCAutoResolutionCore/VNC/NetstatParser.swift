/// `netstat -an -p tcp` 출력에서 VNC 클라이언트를 골라내는 순수 파서.
public enum NetstatParser {
    public static let vncPort = 5900

    /// 로컬 주소가 `.5900`이고 ESTABLISHED인 줄(들어오는 연결)만 클라이언트로 본다.
    /// 나가는 연결(원격 포트가 5900)은 제외한다.
    /// 예: "tcp4  0  0  192.168.0.10.5900  192.168.0.5.54321  ESTABLISHED"
    public static func parse(_ output: String) -> [String] {
        var clients: [String] = []
        for line in output.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 6,
                  cols[0].hasPrefix("tcp"),
                  cols[5] == "ESTABLISHED",
                  cols[3].hasSuffix(".\(vncPort)") else { continue }
            let remote = cols[4]
            let host = remote.lastIndex(of: ".").map { String(remote[..<$0]) } ?? String(remote)
            if !clients.contains(host) { clients.append(host) }
        }
        return clients
    }
}
