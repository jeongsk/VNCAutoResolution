import Foundation

/// 바이트 스트림을 줄바꿈 기준 메시지로 나눈다. TCP는 경계를 보존하지 않으므로
/// 잘려서 오거나 여러 개가 합쳐져 와도 올바른 줄 단위로 돌려준다.
/// 한 줄이 `maxLineLength`를 넘으면 그 줄은 통째로 버린다(메모리 보호).
public struct MessageFramer {
    public let maxLineLength: Int
    /// 크기 제한 때문에 버린 줄 수.
    public private(set) var oversizedCount = 0

    private var buffer = Data()
    /// 크기를 넘긴 줄의 나머지를 줄바꿈이 올 때까지 버리는 중.
    private var discarding = false

    public init(maxLineLength: Int = 4096) {
        self.maxLineLength = maxLineLength
    }

    /// 받은 바이트를 넣고, 이번에 완성된 줄(줄바꿈 제외, 빈 줄 제외)을 돌려준다.
    public mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var rest = data[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let chunk = rest[rest.startIndex..<newline]
            rest = rest[rest.index(after: newline)...]
            if discarding {
                discarding = false
                buffer.removeAll()
            } else if buffer.count + chunk.count > maxLineLength {
                oversizedCount += 1
                buffer.removeAll()
            } else {
                var line = buffer
                line.append(contentsOf: chunk)
                buffer.removeAll()
                if !line.isEmpty { lines.append(line) }
            }
        }
        if !rest.isEmpty && !discarding {
            if buffer.count + rest.count > maxLineLength {
                oversizedCount += 1
                buffer.removeAll()
                discarding = true
            } else {
                buffer.append(contentsOf: rest)
            }
        }
        return lines
    }
}
