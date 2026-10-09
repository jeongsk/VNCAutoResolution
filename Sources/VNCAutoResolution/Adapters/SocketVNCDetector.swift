import Foundation
import VNCAutoResolutionCore

/// VNC 감지 포트의 실제 구현.
/// macOS 27부터 netstat이 TCP 소켓을 보여 주지 않으므로 nettop을 기본으로 읽고,
/// 이전 macOS를 위해 netstat 결과도 합친다.
struct SocketVNCDetector: VNCDetecting {
    func activeClients() -> [String] {
        var clients = NettopParser.parse(run("/usr/bin/nettop", ["-m", "tcp", "-L", "1", "-n", "-J", "state"]))
        for host in NetstatParser.parse(run("/usr/sbin/netstat", ["-an", "-p", "tcp"])) where !clients.contains(host) {
            clients.append(host)
        }
        return clients
    }

    private func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
