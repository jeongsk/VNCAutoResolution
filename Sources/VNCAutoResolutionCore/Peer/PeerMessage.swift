import Foundation

/// 피어 사이에 오가는 메시지. 한 줄짜리 JSON(줄바꿈 구분)으로 직렬화한다.
///
///     hello   { deviceID, name, protocolVersion }   (+ 선택: route)
///     input   { deviceID, sourceID, isKorean }
///     session { deviceID, active }
///
/// `input`과 `session`은 입력 동기화(#5)에서 쓴다. 이 티켓에서는 정의와 전달만 한다.
public enum PeerMessage: Equatable, Sendable {
    /// `route`: 보낸 쪽이 이 연결을 어떤 경로로 걸었는지(걸린 쪽의 메뉴 표시용). 선택 필드.
    case hello(deviceID: String, name: String, protocolVersion: Int, route: PeerRoute?)
    case input(deviceID: String, sourceID: String, isKorean: Bool)
    case session(deviceID: String, active: Bool)

    public static let protocolVersion = 1

    public var deviceID: String {
        switch self {
        case .hello(let id, _, _, _), .input(let id, _, _), .session(let id, _): return id
        }
    }
}

extension PeerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, deviceID, name, protocolVersion, route, sourceID, isKorean, active
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
                route: try? c.decodeIfPresent(PeerRoute.self, forKey: .route)
            )
        case "input":
            self = .input(
                deviceID: deviceID,
                sourceID: try c.decode(String.self, forKey: .sourceID),
                isKorean: try c.decode(Bool.self, forKey: .isKorean)
            )
        case "session":
            self = .session(deviceID: deviceID, active: try c.decode(Bool.self, forKey: .active))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "알 수 없는 메시지 종류: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID, forKey: .deviceID)
        switch self {
        case .hello(_, let name, let version, let route):
            try c.encode("hello", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(version, forKey: .protocolVersion)
            try c.encodeIfPresent(route, forKey: .route)
        case .input(_, let sourceID, let isKorean):
            try c.encode("input", forKey: .type)
            try c.encode(sourceID, forKey: .sourceID)
            try c.encode(isKorean, forKey: .isKorean)
        case .session(_, let active):
            try c.encode("session", forKey: .type)
            try c.encode(active, forKey: .active)
        }
    }
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
