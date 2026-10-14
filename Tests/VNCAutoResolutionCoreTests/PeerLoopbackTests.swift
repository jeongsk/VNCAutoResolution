import XCTest
import Network
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
        /// 파일 전송(가짜 파일 읽기·저장소). 매니저와 같은 큐에서만 만진다.
        let fileTransfer: FileTransferController
        let reader = FakeFileReader()
        let store = FakeFileStore()
        let notifier = FakeFileOfferNotifier()
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
            let fileSettings = InMemoryFileTransferSettings()
            fileSettings.fileReceiveEnabled = true
            fileTransfer = FileTransferController(
                reader: reader, store: store, notifier: notifier, settings: fileSettings,
                peers: manager, clock: SystemClock())
            manager.dataChannelHandler = fileTransfer
            let box = Boxed(manager)
            let events = self.events, messages = self.messages, port = self.port
            let files = Boxed(fileTransfer)
            manager.onMessage = { message, peer in
                switch message {
                case .fileOffer, .fileAnswer, .fileEnd: files.value.handle(message, from: peer)
                default: messages.with { $0.append(message) }
                }
            }
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

    /// 포트가 점유돼 실패했다가 재시도로 열리면 "리스너 시작 실패" 메시지를 비운다 (#11).
    func testListenerFailureStatusClearsAfterRetrySucceeds() throws {
        let (blocker, port) = try makeServer(passphrase: "점유")
        let node = Node(id: "ccc-node", name: "재시도 맥", passphrase: "암호", listenPort: port)
        node.applyConfig()
        XCTAssertTrue(wait { node.queue.sync { node.manager.statusMessage.hasPrefix("리스너 시작 실패") } },
                      "포트 점유 중 실패 메시지가 나와야 함")
        blocker.stop()
        XCTAssertTrue(wait { node.port.with { $0 } == port }, "점유가 풀리면 재시도로 리스너가 열려야 함")
        XCTAssertTrue(wait { node.queue.sync { node.manager.statusMessage.isEmpty } }, "성공 후 실패 메시지가 지워져야 함")
        node.stop()
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

    /// TLS 핸드셰이크(또는 Bonjour 이름 풀이)에서 멈춘 연결은 dialTimeout 뒤 끊고 다시 건다.
    func testStalledDialIsRetriedAfterDialTimeout() throws {
        // TCP만 받고 TLS 응답은 하지 않는 서버: 핸드셰이크가 끝나지 않는다.
        let accepted = Locked<[NWConnection]>([])
        let port = Locked<UInt16?>(nil)
        let raw = try NWListener(using: .tcp, on: .any)
        raw.newConnectionHandler = { c in
            c.start(queue: .global())
            accepted.with { $0.append(c) }
        }
        raw.stateUpdateHandler = { [weak raw] state in
            if case .ready = state { port.with { $0 = raw?.port?.rawValue } }
        }
        raw.start(queue: .global())
        defer { raw.cancel(); accepted.with { $0.forEach { $0.cancel() } } }
        XCTAssertTrue(wait { port.with { $0 } != nil })
        let p = try XCTUnwrap(port.with { $0 })

        let transport = NetworkPeerTransport(
            serviceName: "aaa-client", eventQueue: DispatchQueue(label: "test.stall"),
            options: .init(port: 0, enableBonjour: false, backoff: Backoff(base: 0.1, max: 0.2), dialTimeout: 0.3))
        defer { transport.stop() }
        transport.start { _ in }
        transport.updateConfig(PeerTransportConfig(passphrase: "공유 암호", manualAddress: "127.0.0.1:\(p)"))

        XCTAssertTrue(wait { accepted.with { $0.count } >= 2 }, "멈춘 연결을 다시 걸지 않음")
    }

    // MARK: 파일 전송 (데이터 채널)

    /// 몇 MB짜리 임의 바이트. 줄바꿈과 JSON처럼 보이는 바이트가 섞여 있다.
    private func payload(megabytes: Int) -> Data {
        var data = Data(count: megabytes * 1024 * 1024)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        data.replaceSubrange(0..<16, with: Data("{\"type\":\"x\"}\n\n".utf8))
        return data
    }

    /// `sender`가 `receiver`에게 파일을 보내 받는 쪽이 수락할 때까지. 제안이 오지 않으면 nil.
    private func startTransfer(from sender: Node, to receiver: Node, receiverID: String, data: Data,
                               file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let url = URL(fileURLWithPath: "/tmp/큰 파일.bin")
        sender.queue.sync { sender.reader.files[url.path] = data }
        sender.queue.sync { sender.fileTransfer.send(fileAt: url, to: receiverID) }
        let offered = wait { receiver.queue.sync { receiver.fileTransfer.incomingOffer != nil } }
        guard offered else {
            XCTFail("제안이 도착하지 않음", file: file, line: line)
            return false
        }
        receiver.queue.sync {
            receiver.fileTransfer.accept(transferID: receiver.fileTransfer.incomingOffer!.transferID)
        }
        return true
    }

    /// `sender`가 `receiver`에게 20MB 상한(#18)을 넘는 파일을 보내고, 받는 쪽이 같은 바이트를 저장하는지 확인한다.
    /// 전송 중에도 제어 연결 메시지가 오가는지 함께 본다.
    private func assertFileTransfer(from sender: Node, to receiver: Node, receiverID: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let data = payload(megabytes: 30)
        guard startTransfer(from: sender, to: receiver, receiverID: receiverID, data: data, file: file, line: line)
        else { return }
        let input = PeerMessage.input(deviceID: receiver.manager.deviceID, sourceID: "com.apple.keylayout.ABC", isKorean: false)
        receiver.broadcast(input)

        XCTAssertTrue(wait(30) { receiver.queue.sync { receiver.store.saved.count == 1 } },
                      "파일이 저장되지 않음: \(receiver.queue.sync { receiver.fileTransfer.receiveStatus })",
                      file: file, line: line)
        receiver.queue.sync {
            XCTAssertEqual(receiver.store.saved.first?.name, "큰 파일.bin", file: file, line: line)
            XCTAssertTrue(receiver.store.saved.first?.data == data, "받은 바이트가 다름", file: file, line: line)
        }
        XCTAssertTrue(wait { sender.messages.with { $0.contains(input) } }, "전송 중 제어 메시지가 오가지 않음",
                      file: file, line: line)
        XCTAssertTrue(wait { sender.queue.sync { sender.fileTransfer.sendStatus == .sent(fileName: "큰 파일.bin") } },
                      "보내는 쪽 상태: \(sender.queue.sync { sender.fileTransfer.sendStatus })", file: file, line: line)
        // 데이터 채널은 피어로 등록되지 않는다.
        XCTAssertEqual(sender.peers.count, 1, file: file, line: line)
        XCTAssertEqual(receiver.peers.count, 1, file: file, line: line)
    }

    private func connectedPair() throws -> (client: Node, server: Node) {
        let (server, port) = try makeServer(passphrase: "공유 암호")
        let client = Node(id: "aaa-client", name: "클라이언트 맥", passphrase: "공유 암호",
                          manualAddress: "127.0.0.1:\(port)")
        client.applyConfig()
        XCTAssertTrue(wait { !client.peers.isEmpty && !server.peers.isEmpty }, "hello 교환 실패")
        XCTAssertTrue(wait { client.queue.sync { client.manager.listenPort != nil } })
        return (client, server)
    }

    /// 보내는 쪽이 피어 연결을 건 쪽: 같은 주소로 데이터 채널을 건다.
    func testFileTransferFromDialer() throws {
        let (client, server) = try connectedPair()
        defer { client.stop(); server.stop() }
        assertFileTransfer(from: client, to: server, receiverID: "bbb-server")
    }

    /// 보내는 쪽이 연결을 받은 쪽: 상대 호스트 + 수락 답에 담긴 리스너 포트로 데이터 채널을 건다.
    func testFileTransferFromListener() throws {
        let (client, server) = try connectedPair()
        defer { client.stop(); server.stop() }
        assertFileTransfer(from: server, to: client, receiverID: "aaa-client")
    }

    /// 받는 쪽이 받는 도중 취소하면 임시 파일을 지우고, 보내는 쪽도 취소 상태가 된다.
    func testReceiverCancelMidTransfer() throws {
        let (client, server) = try connectedPair()
        defer { client.stop(); server.stop() }
        server.store.writeDelay = 0.005   // 받는 쪽을 느리게 해 전송 도중에 취소한다.
        XCTAssertTrue(startTransfer(from: client, to: server, receiverID: "bbb-server", data: payload(megabytes: 30)))
        XCTAssertTrue(wait(10) { server.queue.sync {
            if case .receiving(_, let progress) = server.fileTransfer.receiveStatus { return progress.done > 0 }
            return false
        } }, "받기가 시작되지 않음")
        server.queue.sync { server.fileTransfer.cancelReceive() }

        XCTAssertTrue(wait(10) { client.queue.sync {
            client.fileTransfer.sendStatus == .canceled(fileName: "큰 파일.bin", byPeer: true)
        } }, "보내는 쪽 상태: \(client.queue.sync { client.fileTransfer.sendStatus })")
        server.queue.sync {
            XCTAssertEqual(server.fileTransfer.receiveStatus, .canceled(fileName: "큰 파일.bin", byPeer: false))
            XCTAssertEqual(server.store.saved.count, 0)
            XCTAssertEqual(server.store.files.first?.isDiscarded, true)
        }
        XCTAssertEqual(client.peers.count, 1)
        XCTAssertEqual(server.peers.count, 1)
    }
}
