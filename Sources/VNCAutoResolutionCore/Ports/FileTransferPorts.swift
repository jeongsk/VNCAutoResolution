import Foundation

/// 보낼 파일을 읽는 포트.
public protocol LocalFileReading: AnyObject {
    /// 파일 크기(바이트). 읽기 전에 크기 상한을 확인하는 데 쓴다.
    func fileSize(at url: URL) throws -> Int
    func readFile(at url: URL) throws -> Data
}

/// 받은 파일을 저장하는 포트. 실제 구현은 다운로드 폴더에 쓰고 `com.apple.quarantine` 속성을 붙인다.
public protocol ReceivedFileStoring: AnyObject {
    /// `name`(이미 정리된 이름)으로 저장한다. 같은 이름이 있으면 `FileNames.candidates(for:)` 순서로
    /// 덮어쓰지 않는 이름을 고른다. 실제로 저장한 이름을 돌려준다.
    func save(_ data: Data, preferredName name: String) throws -> String
}

/// 받는 쪽에 보여 줄 전송 제안.
public struct IncomingFileOffer: Equatable, Sendable {
    public let transferID: String
    public let deviceID: String
    public let peerName: String
    public let fileName: String
    public let size: Int
}

/// 파일 전송 제안 알림 포트. 알림에서 수락·거절하면 앱이 `FileTransferController.accept/decline`을 부른다.
public protocol FileOfferNotifying: AnyObject {
    func showOffer(_ offer: IncomingFileOffer)
    func removeOffer(transferID: String)
}

/// 파일 전송 설정 저장소 포트. Mac마다 따로 저장한다.
public protocol FileTransferSettingsStoring: AnyObject {
    /// 파일 받기 사용 여부. 기본값 false.
    var fileReceiveEnabled: Bool { get set }
}

/// 메모리 구현 (기본값·테스트용).
public final class InMemoryFileTransferSettings: FileTransferSettingsStoring {
    public var fileReceiveEnabled = false
    public init() {}
}

/// 포트를 주입하지 않은 코어용.
final class NullFileReader: LocalFileReading {
    struct Unavailable: Error {}
    func fileSize(at url: URL) throws -> Int { throw Unavailable() }
    func readFile(at url: URL) throws -> Data { throw Unavailable() }
}

final class NullFileStore: ReceivedFileStoring {
    struct Unavailable: Error {}
    func save(_ data: Data, preferredName name: String) throws -> String { throw Unavailable() }
}

final class NullFileOfferNotifier: FileOfferNotifying {
    func showOffer(_ offer: IncomingFileOffer) {}
    func removeOffer(transferID: String) {}
}
