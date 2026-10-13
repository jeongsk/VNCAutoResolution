import Foundation
import VNCAutoResolutionCore

/// 테스트용 파일 읽기. URL 경로 -> 내용.
final class FakeFileReader: LocalFileReading {
    struct Missing: Error {}
    var files: [String: Data] = [:]
    /// 읽지 않고 크기만 알려 줄 파일 (크기 상한 검사용).
    var sizes: [String: Int] = [:]
    private(set) var readCount = 0

    func fileSize(at url: URL) throws -> Int {
        if let size = sizes[url.path] { return size }
        guard let data = files[url.path] else { throw Missing() }
        return data.count
    }

    func readFile(at url: URL) throws -> Data {
        readCount += 1
        guard let data = files[url.path] else { throw Missing() }
        return data
    }
}

/// 테스트용 저장소. 이미 있는 이름을 피해 번호를 붙인다(실제 구현과 같은 규칙).
final class FakeFileStore: ReceivedFileStoring {
    struct Failed: Error {}
    var existing: Set<String> = []
    var fails = false
    private(set) var saved: [(name: String, data: Data)] = []

    func save(_ data: Data, preferredName name: String) throws -> String {
        if fails { throw Failed() }
        let final = FileNames.candidates(for: name).first { !existing.contains($0) }!
        existing.insert(final)
        saved.append((final, data))
        return final
    }
}

final class FakeFileOfferNotifier: FileOfferNotifying {
    private(set) var shown: [IncomingFileOffer] = []
    private(set) var removed: [String] = []
    func showOffer(_ offer: IncomingFileOffer) { shown.append(offer) }
    func removeOffer(transferID: String) { removed.append(transferID) }
}
