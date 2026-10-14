import Foundation

/// 피어 사이에 오가는 메시지. 한 줄짜리 JSON(줄바꿈 구분)으로 직렬화한다.
///
///     hello   { deviceID, name, protocolVersion }   (+ 선택: route, features)
///     input   { deviceID, sourceID, isKorean }
///     session { deviceID, active }
///     display { deviceID, width, height, scale }   (클라이언트 메인 화면: 포인트 크기 + 배율)
///     clipboard { deviceID, text }                (텍스트 클립보드)
///     fileOffer  { deviceID, transferID, name, size }   (파일 전송 제안)
///     fileAnswer { deviceID, transferID, accepted }   (+ 선택: reason, port)
///     fileEnd    { deviceID, transferID, result }  (전송 결과·취소. 양쪽 어디서든 보낸다)
///     data       { deviceID, transferID }         (데이터 채널의 첫 줄. 이후는 파일 바이트 `size`개 + SHA-256 32바이트)
///
/// `input`과 `session`은 입력 동기화(#5), `display`는 클라이언트 화면 정보(#8), `clipboard`는 클립보드 공유(#17),
/// `fileOffer`·`fileAnswer`·`fileEnd`·`data`는 파일 전송(#18, #19)에서 쓴다.
/// 새 기능은 `protocolVersion`을 올리지 않고 hello의 `features`로 알린다. 예전 버전은 모르는 필드·메시지를 무시한다.
/// 모르는 `type`은 디코딩 실패(nil)로 처리되고, `PeerManager`가 그 줄만 버리고 연결은 유지한다.
public enum PeerMessage: Equatable, Sendable {
    /// `route`: 보낸 쪽이 이 연결을 어떤 경로로 걸었는지(걸린 쪽의 메뉴 표시용). 선택 필드.
    /// `features`: 보낸 쪽이 지원하는 기능 이름(`PeerFeature`). 선택 필드이고, 없으면 빈 목록이다.
    case hello(deviceID: String, name: String, protocolVersion: Int, route: PeerRoute?, features: [String] = [])
    case input(deviceID: String, sourceID: String, isKorean: Bool)
    case session(deviceID: String, active: Bool)
    /// 보낸 쪽(뷰어 앱이 실행 중인 클라이언트)의 메인 화면. width·height는 포인트, scale은 배율.
    case display(deviceID: String, width: Int, height: Int, scale: Double)
    /// 보낸 쪽 클립보드의 일반 텍스트.
    case clipboard(deviceID: String, text: String)
    /// 파일 전송 제안. SHA-256은 데이터 채널에서 파일 바이트 뒤에 붙여 보낸다(보내는 쪽이 읽으면서 계산한다).
    case fileOffer(deviceID: String, transferID: String, name: String, size: Int)
    /// 제안에 대한 답. 수락하면 `port`에 받는 쪽 리스너 포트를 담는다(보내는 쪽이 들어온 연결이라 주소만 알 때 쓴다).
    case fileAnswer(deviceID: String, transferID: String, accepted: Bool, reason: FileDeclineReason?, port: Int?)
    /// 수락한 전송이 끝났다. 받는 쪽은 결과(저장·실패)를, 보내는 쪽은 취소·중단을 알린다.
    case fileEnd(deviceID: String, transferID: String, result: FileEndResult)
    /// 데이터 채널의 첫 줄. 이 줄을 받은 연결은 피어 연결이 아니다.
    case dataChannel(deviceID: String, transferID: String)

    public static let protocolVersion = 1
    /// `clipboard` 텍스트 상한(UTF-8 바이트). 메시지 한 줄 상한(`PeerManager.Limits`)이 이 값에 맞춰 잡힌다.
    public static let maxClipboardTextBytes = 256 * 1024

    public var deviceID: String {
        switch self {
        case .hello(let id, _, _, _, _), .input(let id, _, _), .session(let id, _), .display(let id, _, _, _),
             .clipboard(let id, _), .fileOffer(let id, _, _, _), .fileAnswer(let id, _, _, _, _),
             .fileEnd(let id, _, _), .dataChannel(let id, _): return id
        }
    }
}

extension PeerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, deviceID, name, protocolVersion, route, features, sourceID, isKorean, active, width, height, scale, text
        case transferID, size, accepted, reason, port, result
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let deviceID = try c.decode(String.self, forKey: .deviceID)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(
                deviceID: deviceID,
                name: try c.decode(String.self, forKey: .name),
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                route: try? c.decodeIfPresent(PeerRoute.self, forKey: .route),
                // 모르는 기능 이름은 그대로 두고, 형식이 틀리면 없는 것으로 본다(hello 전체를 버리지 않는다).
                features: (try? c.decodeIfPresent([String].self, forKey: .features)) ?? []
            )
        case "input":
            self = .input(
                deviceID: deviceID,
                sourceID: try c.decode(String.self, forKey: .sourceID),
                isKorean: try c.decode(Bool.self, forKey: .isKorean)
            )
        case "session":
            self = .session(deviceID: deviceID, active: try c.decode(Bool.self, forKey: .active))
        case "display":
            self = .display(
                deviceID: deviceID,
                width: try c.decode(Int.self, forKey: .width),
                height: try c.decode(Int.self, forKey: .height),
                scale: try c.decode(Double.self, forKey: .scale)
            )
        case "clipboard":
            self = .clipboard(deviceID: deviceID, text: try c.decode(String.self, forKey: .text))
        case "fileOffer":
            self = .fileOffer(
                deviceID: deviceID,
                transferID: try c.decode(String.self, forKey: .transferID),
                name: try c.decode(String.self, forKey: .name),
                size: try c.decode(Int.self, forKey: .size))
        case "fileAnswer":
            let accepted = try c.decode(Bool.self, forKey: .accepted)
            // 모르는 거절 사유는 그냥 거절로 본다.
            let reason = accepted ? nil
                : (try? c.decodeIfPresent(FileDeclineReason.self, forKey: .reason)) ?? .declined
            self = .fileAnswer(
                deviceID: deviceID,
                transferID: try c.decode(String.self, forKey: .transferID),
                accepted: accepted, reason: reason,
                port: try? c.decodeIfPresent(Int.self, forKey: .port))
        case "fileEnd":
            self = .fileEnd(
                deviceID: deviceID,
                transferID: try c.decode(String.self, forKey: .transferID),
                // 모르는 결과는 중단으로 본다.
                result: (try? c.decode(FileEndResult.self, forKey: .result)) ?? .interrupted)
        case "data":
            self = .dataChannel(deviceID: deviceID, transferID: try c.decode(String.self, forKey: .transferID))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "알 수 없는 메시지 종류: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID, forKey: .deviceID)
        switch self {
        case .hello(_, let name, let version, let route, let features):
            try c.encode("hello", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(version, forKey: .protocolVersion)
            try c.encodeIfPresent(route, forKey: .route)
            if !features.isEmpty { try c.encode(features, forKey: .features) }
        case .input(_, let sourceID, let isKorean):
            try c.encode("input", forKey: .type)
            try c.encode(sourceID, forKey: .sourceID)
            try c.encode(isKorean, forKey: .isKorean)
        case .session(_, let active):
            try c.encode("session", forKey: .type)
            try c.encode(active, forKey: .active)
        case .display(_, let width, let height, let scale):
            try c.encode("display", forKey: .type)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
            try c.encode(scale, forKey: .scale)
        case .clipboard(_, let text):
            try c.encode("clipboard", forKey: .type)
            try c.encode(text, forKey: .text)
        case .fileOffer(_, let transferID, let name, let size):
            try c.encode("fileOffer", forKey: .type)
            try c.encode(transferID, forKey: .transferID)
            try c.encode(name, forKey: .name)
            try c.encode(size, forKey: .size)
        case .fileAnswer(_, let transferID, let accepted, let reason, let port):
            try c.encode("fileAnswer", forKey: .type)
            try c.encode(transferID, forKey: .transferID)
            try c.encode(accepted, forKey: .accepted)
            try c.encodeIfPresent(reason, forKey: .reason)
            try c.encodeIfPresent(port, forKey: .port)
        case .fileEnd(_, let transferID, let result):
            try c.encode("fileEnd", forKey: .type)
            try c.encode(transferID, forKey: .transferID)
            try c.encode(result, forKey: .result)
        case .dataChannel(_, let transferID):
            try c.encode("data", forKey: .type)
            try c.encode(transferID, forKey: .transferID)
        }
    }
}

/// hello의 `features`에 쓰는 기능 이름.
public enum PeerFeature {
    public static let clipboard = "clipboard"
    public static let fileTransfer = "fileTransfer"
    /// 이 버전이 지원하는 기능. hello로 알린다.
    public static let supported = [clipboard, fileTransfer]
}

/// 파일 전송 제안을 거절한 사유.
public enum FileDeclineReason: String, Codable, Sendable {
    case declined   // 사용자가 거절함
    case timeout    // 60초 안에 응답 없음
    case disabled   // 받기가 꺼져 있음
    case noSpace    // 받는 쪽 디스크 여유 공간 부족
    case busy       // 다른 전송을 처리 중
}

/// 수락한 파일 전송의 끝.
public enum FileEndResult: String, Codable, Sendable {
    case saved              // 받는 쪽이 검증하고 저장함
    case canceled           // 사용자가 취소함
    case checksumMismatch   // 받는 쪽 검증 실패
    case saveFailed         // 받는 쪽 저장 실패
    case interrupted        // 연결이 끊기거나 멈추거나, 보내는 쪽이 파일을 읽지 못함
}

/// 메시지 <-> 한 줄 JSON 변환.
public enum PeerCodec {
    /// 줄바꿈으로 끝나는 한 줄 JSON.
    public static func encode(_ message: PeerMessage) -> Data {
        var data = (try? JSONEncoder().encode(message)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// 줄바꿈이 없는 한 줄을 해석한다. 형식이 틀리거나 모르는 종류면 nil.
    public static func decode(_ line: Data) -> PeerMessage? {
        try? JSONDecoder().decode(PeerMessage.self, from: line)
    }
}
