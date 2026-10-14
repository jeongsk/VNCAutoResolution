import Darwin
import Foundation
import VNCAutoResolutionCore

/// 보낼 파일 읽기 포트의 실제 구현: 파일 시스템.
final class FileSystemFileReader: LocalFileReading {
    func open(_ url: URL) throws -> FileReadHandle {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
        return Handle(try FileHandle(forReadingFrom: url), size: size)
    }

    private final class Handle: FileReadHandle {
        private let handle: FileHandle
        let size: Int

        init(_ handle: FileHandle, size: Int) {
            self.handle = handle
            self.size = size
        }

        func read(upTo count: Int) throws -> Data {
            try handle.read(upToCount: count) ?? Data()
        }

        func close() {
            try? handle.close()
        }
    }
}

/// 받은 파일 저장 포트의 실제 구현: 다운로드 폴더.
///
/// 받는 동안에는 다운로드 폴더 안의 숨긴 임시 파일(`.VNCAutoResolution-<UUID>.download`)에 쓴다.
/// 검증을 마치면 `com.apple.quarantine` 속성을 먼저 붙이고 덮어쓰지 않게 최종 이름으로 바꾼다.
/// (최종 이름의 파일은 격리 속성 없이 존재하는 순간이 없다)
final class DownloadsFileStore: ReceivedFileStoring {
    struct NoFreeName: Error {}
    struct QuarantineFailed: Error {}

    private static let tempPrefix = ".VNCAutoResolution-"
    private static let tempSuffix = ".download"

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func availableBytes() -> Int? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int(clamping: $0) }
    }

    func beginFile() throws -> PartialFile {
        let url = directory.appendingPathComponent(
            "\(Self.tempPrefix)\(UUID().uuidString)\(Self.tempSuffix)", isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            return TempFile(url: url, handle: try FileHandle(forWritingTo: url), directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// 앱이 받는 도중 끝나 남은 임시 파일을 지운다. 앱을 시작할 때 부른다.
    func removeLeftovers() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
        }
    }

    private final class TempFile: PartialFile {
        private let url: URL
        private let handle: FileHandle
        private let directory: URL
        private var isClosed = false

        init(url: URL, handle: FileHandle, directory: URL) {
            self.url = url
            self.handle = handle
            self.directory = directory
        }

        func write(_ data: Data) throws {
            try handle.write(contentsOf: data)
        }

        func commit(preferredName name: String) throws -> String {
            closeHandle()
            try DownloadsFileStore.quarantine(url)
            for candidate in FileNames.candidates(for: name).prefix(1000) {
                let target = directory.appendingPathComponent(candidate, isDirectory: false)
                // RENAME_EXCL: 같은 이름이 있으면 덮어쓰지 않고 EEXIST로 실패한다.
                let result = url.withUnsafeFileSystemRepresentation { from in
                    target.withUnsafeFileSystemRepresentation { to in
                        guard let from, let to else { return Int32(-1) }
                        return renamex_np(from, to, UInt32(RENAME_EXCL))
                    }
                }
                if result == 0 { return candidate }
                if errno == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            throw NoFreeName()
        }

        func discard() {
            closeHandle()
            try? FileManager.default.removeItem(at: url)
        }

        private func closeHandle() {
            guard !isClosed else { return }
            isClosed = true
            try? handle.close()
        }
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
