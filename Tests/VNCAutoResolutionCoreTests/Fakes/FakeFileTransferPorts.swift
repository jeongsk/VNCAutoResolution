import Foundation
import VNCAutoResolutionCore

/// 테스트용 파일 읽기. URL 경로 -> 내용.
final class FakeFileReader: LocalFileReading {
    struct Missing: Error {}
    var files: [String: Data] = [:]
    /// 열린 파일. (몇 번째 조각에서 읽기 실패를 내거나, 닫혔는지 확인하는 데 쓴다)
    private(set) var opened: [FakeReadHandle] = []

    func open(_ url: URL) throws -> FileReadHandle {
        guard let data = files[url.path] else { throw Missing() }
        let handle = FakeReadHandle(data)
        opened.append(handle)
        return handle
    }
}

final class FakeReadHandle: FileReadHandle {
    struct Failed: Error {}
    private let data: Data
    private var offset = 0
    /// 이 바이트 위치부터 읽기 실패.
    var failsAt: Int?
    /// 읽은 조각 크기(요청한 순서).
    private(set) var reads: [Int] = []
    private(set) var isClosed = false

    init(_ data: Data) { self.data = data }

    var size: Int { data.count }

    func read(upTo count: Int) throws -> Data {
        if let failsAt, offset >= failsAt { throw Failed() }
        let chunk = data[data.startIndex + offset ..< data.startIndex + min(data.count, offset + count)]
        offset += chunk.count
        reads.append(chunk.count)
        return Data(chunk)
    }

    func close() { isClosed = true }
}

/// 테스트용 저장소. 임시 파일은 메모리에 두고, 이미 있는 이름을 피해 번호를 붙인다(실제 구현과 같은 규칙).
final class FakeFileStore: ReceivedFileStoring {
    struct Failed: Error {}
    var existing: Set<String> = []
    var free: Int?
    var beginFails = false
    var writeFails = false
    var commitFails = false
    /// 쓰기마다 이만큼 멈춘다(loopback 테스트에서 받는 쪽을 느리게 할 때).
    var writeDelay: TimeInterval = 0
    private(set) var files: [FakePartialFile] = []
    private(set) var saved: [(name: String, data: Data)] = []

    func availableBytes() -> Int? { free }

    func beginFile() throws -> PartialFile {
        if beginFails { throw Failed() }
        let file = FakePartialFile(store: self)
        files.append(file)
        return file
    }

    fileprivate func commit(_ file: FakePartialFile, name: String) throws -> String {
        if commitFails { throw Failed() }
        let final = FileNames.candidates(for: name).first { !existing.contains($0) }!
        existing.insert(final)
        saved.append((final, file.data))
        return final
    }
}

final class FakePartialFile: PartialFile {
    private unowned let store: FakeFileStore
    private(set) var data = Data()
    private(set) var isCommitted = false
    private(set) var isDiscarded = false

    fileprivate init(store: FakeFileStore) { self.store = store }

    func write(_ chunk: Data) throws {
        if store.writeFails { throw FakeFileStore.Failed() }
        if store.writeDelay > 0 { Thread.sleep(forTimeInterval: store.writeDelay) }
        data.append(chunk)
    }

    func commit(preferredName name: String) throws -> String {
        let final = try store.commit(self, name: name)
        isCommitted = true
        return final
    }

    func discard() {
        isDiscarded = true
        data = Data()
    }
}

final class FakeFileOfferNotifier: FileOfferNotifying {
    private(set) var shown: [IncomingFileOffer] = []
    private(set) var removed: [String] = []
    func showOffer(_ offer: IncomingFileOffer) { shown.append(offer) }
    func removeOffer(transferID: String) { removed.append(transferID) }
}
