import Darwin
import Foundation
import VNCAutoResolutionCore

/// 보낼 파일 읽기 포트의 실제 구현: 파일 시스템.
final class FileSystemFileReader: LocalFileReading {
    func fileSize(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
        return size
    }

    func readFile(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

/// 받은 파일 저장 포트의 실제 구현: 다운로드 폴더. 덮어쓰지 않고, `com.apple.quarantine` 속성을 붙인다.
final class DownloadsFileStore: ReceivedFileStoring {
    struct NoFreeName: Error {}
    struct QuarantineFailed: Error {}

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func save(_ data: Data, preferredName name: String) throws -> String {
        for candidate in FileNames.candidates(for: name).prefix(1000) {
            let url = directory.appendingPathComponent(candidate, isDirectory: false)
            do {
                try data.write(to: url, options: .withoutOverwriting)
            } catch CocoaError.fileWriteFileExists {
                continue
            }
            do {
                try Self.quarantine(url)
            } catch {
                try? FileManager.default.removeItem(at: url)   // 격리 속성 없이 남기지 않는다.
                throw error
            }
            return candidate
        }
        throw NoFreeName()
    }

    /// 브라우저로 받은 파일과 같은 형식의 격리 속성. 열 때 Gatekeeper가 확인한다.
    private static func quarantine(_ url: URL) throws {
        let value = String(format: "0083;%08lx;VNCAutoResolution;", Int(Date().timeIntervalSince1970))
        let ok = value.withCString { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                return setxattr(path, "com.apple.quarantine", bytes, strlen(bytes), 0, 0) == 0
            }
        }
        if !ok { throw QuarantineFailed() }
    }
}

/// 파일 전송 설정 저장소 포트의 실제 구현: UserDefaults. 값이 없으면 기본값 false.
final class UserDefaultsFileTransferSettings: FileTransferSettingsStoring {
    private let defaults: UserDefaults

    private enum Keys {
        static let receiveEnabled = "fileReceiveEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var fileReceiveEnabled: Bool {
        get { defaults.bool(forKey: Keys.receiveEnabled) }
        set { defaults.set(newValue, forKey: Keys.receiveEnabled) }
    }
}
