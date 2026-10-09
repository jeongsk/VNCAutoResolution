import XCTest
@testable import VNCAutoResolutionCore

/// 테스트 안에서 여러 큐가 함께 쓰는 값 상자.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// 비-Sendable 값을 직렬 큐 안에서만 만진다는 전제로 클로저에 넘기기 위한 상자.
private final class Boxed<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// 실제 TLS-PSK 전송 + 피어 매니저를 localhost에서 맞붙인다 (Bonjour 없이 직접 host:port).
final class PeerLoopbackTests: XCTestCase {
    /// 전송 하나 + 매니저 하나. 매니저는 자기 직렬 큐에서만 만진다.
    private final class Node {
        let queue: DispatchQueue
        let transport: NetworkPeerTransport
        let manager: PeerManager
        let stores: InMemoryPeerStores
        let events = Locked<[PeerTransportEvent]>([])
        let messages = Locked<[PeerMessage]>([])
        let port = Locked<UInt16?>(nil)

        init(id: String, name: String, passphrase: String, manualAddress: String = "", listenPort: UInt16 = 0) {
            let queue = DispatchQueue(label: "test.node.\(id)")
            self.queue = queue
            stores = InMemoryPeerStores(deviceID: id, manualPeerAddress: manualAddress, passphrase: passphrase)
            transport = NetworkPeerTransport(
                serviceName: id, eventQueue: queue,
                options: .init(port: listenPort, enableBonjour: false, backoff: Backoff(base: 0.2, max: 0.5)))
            manager = PeerManager(
                deviceName: name, transport: transport, settings: stores, secrets: stores,
                clock: SystemClock())
            let box = Boxed(manager)
            let events = self.events, messages = self.messages, port = self.port
            manager.onMessage = { message, _ in messages.with { $0.append(message) } }
            transport.onListening = { p in port.with { $0 = p } }
            transport.start { event in
                events.with { $0.append(event) }
                box.value.handle(event)
            }
        }

        func applyConfig() { queue.sync { manager.applyStoredConfig() } }
        var peers: [PeerManager.Peer] { queue.sync { manager.peers } }
        func broadcast(_ m: PeerMessage) { queue.sync { manager.broadcast(m) } }
        var connectedCount: Int {
            events.with { $0.filter { if case .connected = $0 { return true } else { return false } }.count }
        }
        func stop() { transport.stop() }
    }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// 리스너를 띄우고 실제 포트를 얻는다.
    private func makeServer(passphrase: String, listenPort: UInt16 = 0) throws -> (Node, UInt16) {
        let server = Node(id: "bbb-server", name: "서버 맥", passphrase: passphrase, listenPort: listenPort)
        server.applyConfig()
        XCTAssertTrue(wait { server.port.with { $0 } != nil }, "리스너가 열리지 않음")
        return (server, try XCTUnwrap(server.port.with { $0 }))
    }

    func testSamePassphraseConnectsAndMessagesRoundTrip() throws {
        let (server, port) = try makeServer(passphrase: "공유 암호")
        defer { server.stop() }
        let client = Node(id: "aaa-client", name: "클라이언트 맥", passphrase: "공유 암호",
                          manualAddress: "127.0.0.1:\(port)")
        defer { client.stop() }
        client.applyConfig()

        XCTAssertTrue(wait { !client.peers.isEmpty && !server.peers.isEmpty }, "hello 교환 실패")
        XCTAssertEqual(client.peers.map(\.name), ["서버 맥"])
        XCTAssertEqual(client.peers.first?.route, .manual)
        XCTAssertEqual(server.peers.map(\.name), ["클라이언트 맥"])
        XCTAssertEqual(server.peers.first?.route, .manual) // hello 의 route 힌트

        let input = PeerMessage.input(deviceID: "aaa-client", sourceID: "com.apple.keylayout.ABC", isKorean: false)
        let session = PeerMessage.session(deviceID: "bbb-server", active: true)
        client.broadcast(input)
        server.broadcast(session)
        XCTAssertTrue(wait {
            server.messages.with { $0 } == [input] && client.messages.with { $0 } == [session]
        }, "메시지 왕복 실패")
    }

    func testDifferentPassphraseIsRejected() throws {
        let (server, port) = try makeServer(passphrase: "서버 암호")
        defer { server.stop() }
        let client = Node(id: "aaa-client", name: "클라이언트 맥", passphrase: "다른 암호",
                          manualAddress: "127.0.0.1:\(port)")
        defer { client.stop() }
        client.applyConfig()

        // 핸드셰이크가 실패하므로 어느 쪽에도 connected 가 올라오면 안 된다. (재시도 포함 1.5초 관찰)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(server.connectedCount, 0)
        XCTAssertEqual(client.connectedCount, 0)
        XCTAssertTrue(server.peers.isEmpty)
        XCTAssertTrue(client.peers.isEmpty)
    }

    func testReconnectsWithBackoffAfterServerRestarts() throws {
        let (server, port) = try makeServer(passphrase: "공유 암호")
        let client = Node(id: "aaa-client", name: "클라이언트 맥", passphrase: "공유 암호",
                          manualAddress: "127.0.0.1:\(port)")
        defer { client.stop() }
        client.applyConfig()
        XCTAssertTrue(wait { !client.peers.isEmpty })

        server.stop()
        XCTAssertTrue(wait { client.peers.isEmpty }, "연결 종료가 반영되지 않음")

        // 같은 포트로 서버가 다시 뜨면 클라이언트가 백오프 후 스스로 다시 연결한다.
        let (restarted, _) = try makeServer(passphrase: "공유 암호", listenPort: port)
        defer { restarted.stop() }
        XCTAssertTrue(wait { !client.peers.isEmpty && !restarted.peers.isEmpty }, "재연결 실패")
    }
}
