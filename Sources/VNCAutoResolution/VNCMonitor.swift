import Foundation

/// 화면 공유(VNC, TCP 5900) 접속 여부를 netstat으로 확인한다.
enum VNCMonitor {
    static let port = 5900

    /// 현재 5900 포트에 ESTABLISHED 상태로 붙어 있는 클라이언트 주소 목록.
    static func activeClients() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-an", "-p", "tcp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// 예: "tcp4  0  0  192.168.0.10.5900  192.168.0.5.54321  ESTABLISHED"
    static func parse(_ output: String) -> [String] {
        var clients: [String] = []
        for line in output.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 6,
                  cols[0].hasPrefix("tcp"),
                  cols[5] == "ESTABLISHED",
                  cols[3].hasSuffix(".\(port)") else { continue }
            let remote = cols[4]
            let host = remote.lastIndex(of: ".").map { String(remote[..<$0]) } ?? String(remote)
            if !clients.contains(host) { clients.append(host) }
        }
        return clients
    }
}
