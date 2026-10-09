import Foundation
import VNCAutoResolutionCore

/// VNC 감지 포트의 실제 구현: netstat 출력을 파싱한다.
struct NetstatVNCDetector: VNCDetecting {
    func activeClients() -> [String] {
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
        return NetstatParser.parse(String(decoding: data, as: UTF8.self))
    }
}
