import Darwin
import Foundation
import SlidesBridgeKit

// Runs the real app-side bridge and Safari relay. UnixBridge.sendOnce stands in
// for the Safari extension handler; `Inbox` stands in for SFSafariApplication.
// Run scripts/test-safari-relay.sh on macOS.
@main
struct SafariRelayChecks {
    private static var checkCount = 0

    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: "/tmp/lp-safari-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bridge = directory.appendingPathComponent("bridge/bridge.sock").path
        let relaySocket = directory.appendingPathComponent("bridge/relay.sock").path
        let controller = BrowserPresentationController(socketPath: bridge)
        let inbox = Inbox()
        let relay = SafariRelay(listenPath: relaySocket, bridgePath: bridge, deliver: { inbox.append($0) })
        defer {
            relay.stop()
            controller.stopListening()
            try? FileManager.default.removeItem(at: directory)
        }
        try controller.startListening()
        try relay.start()
        controller.onPairingRequested = {
            Task { await controller.connect() }
            return nil
        }
        func send(_ message: BridgeMessage) throws -> Bool { try UnixBridge.sendOnce(message, path: relaySocket) }

        let snapshot = SlideSnapshot(deckID: "test-deck", title: "Safari test", pageID: "page-one", slideID: "slide-one", position: 1, total: 3)
        let session = UUID().uuidString
        try check(!(try send(BridgeMessage(type: .command, session: session, requestID: 1, operation: .status))),
                  "Relay refuses commands from the extension")
        try check(!(try send(BridgeMessage(type: .result, session: session, requestID: 1, snapshot: snapshot))),
                  "Relay refuses results before hello")
        try check(try send(BridgeMessage(type: .hello, session: session, snapshot: snapshot)), "Relay accepts hello")
        let status = try await inbox.next()
        try check(status.type == .command && status.operation == .status && status.session == session,
                  "LocalPrompt's status command reaches the extension")
        try check(!(try send(BridgeMessage(type: .result, session: UUID().uuidString, requestID: status.requestID, snapshot: snapshot))),
                  "Relay refuses a result from another session")
        try check(try send(BridgeMessage(type: .result, session: session, requestID: status.requestID, snapshot: snapshot)),
                  "Relay forwards the extension's result")
        try await until { controller.isConnected }
        try check(controller.status.contains("slide 1 of 3"), "Safari pairing shows the confirmed slide")

        controller.disconnect()
        let ended = try await inbox.next()
        try check(ended.type == .disconnect && ended.session == session, "Disconnecting in LocalPrompt tells the extension")
        try check(!(try send(BridgeMessage(type: .result, session: session, requestID: status.requestID, snapshot: snapshot))),
                  "Relay refuses results after the session ends")

        let second = UUID().uuidString
        try check(try send(BridgeMessage(type: .hello, session: second, snapshot: snapshot)), "A new hello starts a new session")
        let secondStatus = try await inbox.next()
        try check(secondStatus.session == second, "Commands use the new session")
        controller.stopListening()
        let closed = try await inbox.next()
        try check(closed.type == .disconnect && closed.session == second, "Closing LocalPrompt's bridge tells the extension")
        try check(!(try send(BridgeMessage(type: .hello, session: UUID().uuidString, snapshot: snapshot))),
                  "Hello fails while LocalPrompt is not listening")
        try await inbox.expectQuiet()
        print("Safari relay: \(checkCount) checks passed")
    }

    private static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure(name: name) }
        checkCount += 1
    }

    @MainActor
    private static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        guard condition() else { throw Failure(name: "Timed out waiting for the app") }
    }

    struct Failure: Error, CustomStringConvertible {
        let name: String
        var description: String { "Safari relay check failed: \(name)" }
    }
}

/// Frames the relay would hand to Safari.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[String: Any]] = []

    func append(_ frame: [String: Any]) { lock.lock(); frames.append(frame); lock.unlock() }

    private func take() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return frames.isEmpty ? nil : frames.removeFirst()
    }

    func next() async throws -> BridgeMessage {
        for _ in 0..<300 {
            if let frame = take() {
                let data = try JSONSerialization.data(withJSONObject: frame)
                return try BridgeFraming.decode(data)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw SafariRelayChecks.Failure(name: "No frame reached the extension")
    }

    func expectQuiet() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        guard take() == nil else { throw SafariRelayChecks.Failure(name: "Unexpected extra frame") }
    }
}
