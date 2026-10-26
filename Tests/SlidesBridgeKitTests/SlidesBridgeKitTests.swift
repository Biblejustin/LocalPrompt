import Darwin
import Foundation
import XCTest
@testable import SlidesBridgeKit

final class SlidesBridgeKitTests: XCTestCase {
    private let session = "65ce251a-0634-4d8a-b10b-fb95e8274221"
    private var snapshot: SlideSnapshot { SlideSnapshot(deckID: "test-deck", title: "Synthetic test", pageID: "test-page", slideID: "slide-one", position: 1, total: 3) }

    func testFrameSurvivesEveryByteBoundaryAndUnicode() throws {
        var snap = snapshot; snap.title = "Café 🌿"
        let message = BridgeMessage(type: .hello, session: session, snapshot: snap)
        let frame = try BridgeFraming.encode(message)
        var decoder = BridgeFrameDecoder()
        var output: [BridgeMessage] = []
        for byte in frame { output += try decoder.append(Data([byte])) }
        XCTAssertEqual(output, [message])
        XCTAssertFalse(decoder.hasPartialFrame)
    }

    func testCoalescedMessagesAndPartialTail() throws {
        let hello = BridgeMessage(type: .hello, session: session, snapshot: snapshot)
        let result = BridgeMessage(type: .result, session: session, requestID: 1, snapshot: snapshot)
        let frame = try BridgeFraming.encode(result)
        var data = try BridgeFraming.encode(hello)
        data.append(frame.prefix(5))
        var decoder = BridgeFrameDecoder()
        XCTAssertEqual(try decoder.append(data), [hello])
        XCTAssertTrue(decoder.hasPartialFrame)
        XCTAssertEqual(try decoder.append(Data(frame.dropFirst(5))), [result])
        XCTAssertFalse(decoder.hasPartialFrame)
    }

    func testRejectsEmptyOversizedAndMalformedFrames() throws {
        for bytes: [UInt8] in [[0, 0, 0, 0], [1, 0, 1, 0], [1, 0, 0, 0, 255]] {
            var decoder = BridgeFrameDecoder()
            XCTAssertThrowsError(try decoder.append(Data(bytes)))
        }
    }

    func testProtocolBoundsAndVersion() throws {
        var message = BridgeMessage(type: .hello, session: session, snapshot: snapshot)
        message.v = 2
        XCTAssertThrowsError(try BridgeFraming.encode(message))
        message.v = 1; message.session = "short"
        XCTAssertThrowsError(try BridgeFraming.encode(message))
        message.session = session; message.snapshot?.position = 0
        XCTAssertThrowsError(try BridgeFraming.encode(message))
        message.snapshot = snapshot; message.snapshot?.title = String(repeating: "x", count: 2_049)
        XCTAssertThrowsError(try BridgeFraming.encode(message))
        XCTAssertThrowsError(try BridgeFraming.encode(BridgeMessage(type: .command, session: session, requestID: 1, operation: .advance)))
        XCTAssertThrowsError(try BridgeFraming.encode(BridgeMessage(type: .result, session: session, requestID: 0, snapshot: snapshot)))
    }

    func testPrivateSocketRoundTripAndDuplicateServerLock() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("bridge/bridge.sock").path
        let gotHello = expectation(description: "hello")
        let gotResult = expectation(description: "result")
        let clientBox = LockedBox<UUID>()
        let server = UnixBridgeServer(path: path) { event in
            if case .message(let client, let message) = event {
                if message.type == .hello { clientBox.value = client; gotHello.fulfill() }
                if message.type == .result { gotResult.fulfill() }
            }
        }
        try server.start()
        defer { server.stop() }
        let fd = try UnixBridge.connect(path: path)
        defer { Darwin.close(fd) }
        try UnixBridge.write(BridgeFraming.encode(BridgeMessage(type: .hello, session: session, snapshot: snapshot)), to: fd)
        wait(for: [gotHello], timeout: 2)

        let second = UnixBridgeServer(path: path) { _ in }
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? SlidesBridgeError, .alreadyRunning) }
        let sent = expectation(description: "command sent")
        let command = BridgeMessage(type: .command, session: session, requestID: 1, operation: .status, snapshot: snapshot)
        server.send(command, to: try XCTUnwrap(clientBox.value)) { error in XCTAssertNil(error); sent.fulfill() }
        XCTAssertEqual(try readMessage(fd), command)
        wait(for: [sent], timeout: 2)
        try UnixBridge.write(BridgeFraming.encode(BridgeMessage(type: .result, session: session, requestID: 1, snapshot: snapshot)), to: fd)
        wait(for: [gotResult], timeout: 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("bridge").path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testRejectsSymlinkDirectoryAndExistingRegularSocketFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("bridge")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = UnixBridgeServer(path: link.appendingPathComponent("bridge.sock").path) { _ in }
        XCTAssertThrowsError(try linked.start())
        let directPath = target.appendingPathComponent("bridge.sock")
        try Data("unrelated".utf8).write(to: directPath)
        let direct = UnixBridgeServer(path: directPath.path) { _ in }
        XCTAssertThrowsError(try direct.start())
        XCTAssertEqual(try String(contentsOf: directPath, encoding: .utf8), "unrelated")
    }

    func testSecondClientClosesBothRatherThanReplacingConnectedDeck() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("bridge/bridge.sock").path
        let hello = expectation(description: "first hello")
        let ambiguous = expectation(description: "ambiguous")
        let server = UnixBridgeServer(path: path) { event in
            if case .message = event { hello.fulfill() }
            if case .ambiguous = event { ambiguous.fulfill() }
        }
        try server.start(); defer { server.stop() }
        let first = try UnixBridge.connect(path: path); defer { Darwin.close(first) }
        try UnixBridge.write(BridgeFraming.encode(BridgeMessage(type: .hello, session: session, snapshot: snapshot)), to: first)
        wait(for: [hello], timeout: 2)
        let second = try UnixBridge.connect(path: path); defer { Darwin.close(second) }
        wait(for: [ambiguous], timeout: 2)
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/lp-test-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func readMessage(_ fd: Int32) throws -> BridgeMessage {
        var decoder = BridgeFrameDecoder()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 1_000) > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw SlidesBridgeError.disconnected }
            if let message = try decoder.append(Data(bytes.prefix(count))).first { return message }
        }
        throw SlidesBridgeError.timeout
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
