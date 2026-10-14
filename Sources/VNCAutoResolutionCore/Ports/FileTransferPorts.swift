import Foundation

/// 보낼 파일을 읽는 포트.
public protocol LocalFileReading: AnyObject {
    /// 보낼 파일을 연다. 일반 파일이 아니거나 읽을 수 없으면 던진다.
    func open(_ url: URL) throws -> FileReadHandle
}

/// 연 파일. 앞에서부터 조각 단위로 읽는다.
public protocol FileReadHandle: AnyObject {
    /// 연 시점의 크기(바이트).
    var size: Int { get }
    /// 다음 조각을 최대 `count`바이트 읽는다. 파일 끝이면 빈 `Data`.
    func read(upTo count: Int) throws -> Data
    func close()
}

/// 받은 파일을 저장하는 포트. 실제 구현은 다운로드 폴더 안의 임시 파일에 이어 쓰고,
/// 검증을 마치면 `com.apple.quarantine` 속성을 붙여 최종 이름으로 바꾼다.
public protocol ReceivedFileStoring: AnyObject {
    /// 저장할 볼륨의 여유 공간(바이트). 알 수 없으면 nil(크기 확인을 건너뛴다).
    func availableBytes() -> Int?
    /// 임시 파일을 새로 만든다.
    func beginFile() throws -> PartialFile
}

/// 받는 중인 임시 파일.
public protocol PartialFile: AnyObject {
    /// 끝에 이어 쓴다.
    func write(_ data: Data) throws
    /// 격리 속성을 붙이고 `name`(이미 정리된 이름)으로 바꾼다. 같은 이름이 있으면 `FileNames.candidates(for:)` 순서로
    /// 덮어쓰지 않는 이름을 고른다. 실제로 쓴 이름을 돌려준다. 던지면 부르는 쪽이 `discard()`한다.
    func commit(preferredName name: String) throws -> String
    /// 임시 파일을 지운다. 여러 번 불러도 된다.
    func discard()
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
    func open(_ url: URL) throws -> FileReadHandle { throw Unavailable() }
}

final class NullFileStore: ReceivedFileStoring {
    struct Unavailable: Error {}
    func availableBytes() -> Int? { nil }
    func beginFile() throws -> PartialFile { throw Unavailable() }
}

final class NullFileOfferNotifier: FileOfferNotifying {
    func showOffer(_ offer: IncomingFileOffer) {}
    func removeOffer(transferID: String) {}
}
