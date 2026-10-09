import Foundation

/// 피어 사이에 오가는 메시지. 한 줄짜리 JSON(줄바꿈 구분)으로 직렬화한다.
///
///     hello   { deviceID, name, protocolVersion }   (+ 선택: route)
///     input   { deviceID, sourceID, isKorean }
///     session { deviceID, active }
///     display { deviceID, width, height, scale }   (클라이언트 메인 화면: 포인트 크기 + 배율)
///
/// `input`과 `session`은 입력 동기화(#5), `display`는 클라이언트 화면 정보(#8)에서 쓴다.
/// 모르는 `type`은 디코딩 실패(nil)로 처리되고, `PeerManager`가 그 줄만 버리고 연결은 유지한다.
public enum PeerMessage: Equatable, Sendable {
    /// `route`: 보낸 쪽이 이 연결을 어떤 경로로 걸었는지(걸린 쪽의 메뉴 표시용). 선택 필드.
    case hello(deviceID: String, name: String, protocolVersion: Int, route: PeerRoute?)
    case input(deviceID: String, sourceID: String, isKorean: Bool)
    case session(deviceID: String, active: Bool)
    /// 보낸 쪽(뷰어 앱이 실행 중인 클라이언트)의 메인 화면. width·height는 포인트, scale은 배율.
    case display(deviceID: String, width: Int, height: Int, scale: Double)

    public static let protocolVersion = 1

    public var deviceID: String {
        switch self {
        case .hello(let id, _, _, _), .input(let id, _, _), .session(let id, _), .display(let id, _, _, _): return id
        }
    }
}

extension PeerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, deviceID, name, protocolVersion, route, sourceID, isKorean, active, width, height, scale
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
        case "display":
            self = .display(
                deviceID: deviceID,
                width: try c.decode(Int.self, forKey: .width),
                height: try c.decode(Int.self, forKey: .height),
                scale: try c.decode(Double.self, forKey: .scale)
            )
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
        case .display(_, let width, let height, let scale):
            try c.encode("display", forKey: .type)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
            try c.encode(scale, forKey: .scale)
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
