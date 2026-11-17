import Darwin
import Foundation
import SlidesBridgeKit

// Compiles the actual app controller without launching the app or touching its
// preferences. Run scripts/test-browser-pairing.sh on macOS.
@main
struct BrowserPairingChecks {
    private static var checkCount = 0
    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: "/tmp/lp-pair-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let socket = directory.appendingPathComponent("bridge/bridge.sock").path
        let controller = BrowserPresentationController(socketPath: socket)
        defer {
            controller.stopListening()
            try? FileManager.default.removeItem(at: directory)
        }
        try controller.startListening()
        var requests = 0
        controller.onPairingRequested = {
            requests += 1
            Task { await controller.connect() }
            return nil
        }
        let snapshot = SlideSnapshot(deckID: "test-deck", title: "Pairing test", pageID: "page-one", slideID: "slide-one", position: 1, total: 3)
        let firstSession = UUID().uuidString
        let first = try Peer(socket: socket)
        try first.send(BridgeMessage(type: .hello, session: firstSession, snapshot: snapshot))
        let status = try await first.message()
        try check(status.type == .command && status.operation == .status, "Pairing sends status only")
        try check(status.snapshot == snapshot, "Pairing checks the selected slide")
        try check(!controller.isConnected && controller.isBusy, "Unacknowledged connection stays pending")
        try first.send(BridgeMessage(type: .result, session: firstSession, requestID: status.requestID, snapshot: snapshot))
        try await until { controller.isConnected }
        try check(requests == 1 && !controller.isBusy, "One hello pairs without an app button")
        try check(controller.status.contains("slide 1 of 3"), "Pairing displays confirmed position")
        try await first.expectQuiet()
        controller.disconnect()
        try await first.expectClosed()
        try check(!controller.hasCandidate && !controller.isConnected, "Disconnect clears binding")

        // A busy app must decline the selection before issuing any command.
        controller.onPairingRequested = { "Pause reading before connecting." }
        let rejected = try Peer(socket: socket)
        let rejectedSession = UUID().uuidString
        try rejected.send(BridgeMessage(type: .hello, session: rejectedSession, snapshot: snapshot))
        let rejection = try await rejected.message()
        try check(rejection.type == .disconnect && rejection.error == "Pause reading before connecting.", "Browser receives pairing rejection reason")
        try check(rejection.session == rejectedSession, "Rejection addresses only the requesting session")
        try await rejected.expectClosed()
        try await until { controller.errorMessage != nil }
        try check(controller.errorMessage == "Pause reading before connecting.", "Rejected pairing exposes its reason")
        try check(!controller.isConnected && !controller.hasCandidate, "Rejected pairing leaves no candidate")

        // A controller that has not attached the app callback cannot auto-arm.
        controller.onPairingRequested = nil
        let unready = try Peer(socket: socket)
        try unready.send(BridgeMessage(type: .hello, session: UUID().uuidString, snapshot: snapshot))
        let unreadyReason = try await unready.message()
        try check(unreadyReason.type == .disconnect && unreadyReason.error != nil, "Unready app explains rejection to browser")
        try await unready.expectClosed()
        try check(!controller.isConnected && !controller.hasCandidate, "Missing app callback rejects pairing")

        controller.onPairingRequested = {
            requests += 1
            Task { await controller.connect() }
            return nil
        }
        let canceled = try Peer(socket: socket)
        let canceledSession = UUID().uuidString
        try canceled.send(BridgeMessage(type: .hello, session: canceledSession, snapshot: snapshot))
        let canceledStatus = try await canceled.message()
        controller.disconnect()
        // A result already queued by the browser must not restore this session.
        try? canceled.send(BridgeMessage(type: .result, session: canceledSession, requestID: canceledStatus.requestID, snapshot: snapshot))
        try await canceled.expectClosed()
        try await Task.sleep(for: .milliseconds(30))
        try check(!controller.isConnected && !controller.hasCandidate && !controller.isBusy, "Canceled handshake cannot reconnect")

        let current = try Peer(socket: socket)
        let currentSession = UUID().uuidString
        var currentSnapshot = snapshot
        currentSnapshot.pageID = "page-two"
        currentSnapshot.position = 2
        currentSnapshot.slideID = "slide-two"
        try current.send(BridgeMessage(type: .hello, session: currentSession, snapshot: currentSnapshot))
        let currentStatus = try await current.message()
        try check(currentStatus.requestID! > canceledStatus.requestID!, "Requests remain monotonic across sessions")
        try current.send(BridgeMessage(type: .result, session: canceledSession, requestID: currentStatus.requestID, snapshot: currentSnapshot))
        try await Task.sleep(for: .milliseconds(30))
        try check(!controller.isConnected && controller.isBusy, "Old session cannot confirm new pairing")
        try current.send(BridgeMessage(type: .result, session: currentSession, requestID: currentStatus.requestID, snapshot: currentSnapshot))
        try await until { controller.isConnected }
        try check(controller.status.contains("slide 2 of 3"), "New session uses its own confirmed position")
        // Duplicate acknowledgements do not trigger commands or alter position.
        try current.send(BridgeMessage(type: .result, session: currentSession, requestID: currentStatus.requestID, snapshot: snapshot))
        try await current.expectQuiet()
        try check(controller.isConnected && controller.status.contains("slide 2 of 3"), "Duplicate status result is ignored")
        controller.disconnect()
        try await current.expectClosed()
        try await manualSyncChecks(controller, socket: socket, initial: snapshot)
        try await positionRefreshChecks(controller, socket: socket, initial: snapshot)
        print("Browser pairing and manual sync: \(checkCount) checks passed")
    }

    static func check(_ condition: Bool, _ label: String) throws {
        checkCount += 1
        guard condition else { throw CheckFailure(description: label) }
    }

    @MainActor
    private static func pair(_ controller: BrowserPresentationController, socket: String, snapshot: SlideSnapshot) async throws -> (Peer, String) {
        let peer = try Peer(socket: socket)
        let session = UUID().uuidString
        try peer.send(BridgeMessage(type: .hello, session: session, snapshot: snapshot))
        let status = try await peer.message()
        try peer.send(BridgeMessage(type: .result, session: session, requestID: status.requestID, snapshot: snapshot))
        try await until { controller.isConnected }
        return (peer, session)
    }

    @MainActor
    private static func manualSyncChecks(_ controller: BrowserPresentationController, socket: String, initial: SlideSnapshot) async throws {
        let (peer, session) = try await pair(controller, socket: socket, snapshot: initial)
        var expected = initial
        try check(controller.currentSlidePosition == 1 && controller.totalSlides == 3, "Connected metadata exposes slide bounds")
        for destination in [3, 1, 1] {
            let movement = Task { try await controller.goToSlide(destination) }
            let command = try await peer.message()
            try check(command.operation == .goToSlide && command.targetPosition == destination && command.snapshot == expected,
                      "Forward, backward and same-slide sync use one checked direct command")
            var result = expected
            result.position = destination
            result.slideID = destination == 1 ? "slide-one" : "slide-three"
            try peer.send(BridgeMessage(type: .result, session: session, requestID: command.requestID, snapshot: result))
            try await movement.value
            try check(controller.currentSlidePosition == destination && !controller.isBusy && controller.isConnected,
                      "Only the exact confirmed destination updates connection metadata")
            try await peer.expectQuiet()
            expected = result
        }
        for invalid in [0, 4] {
            do {
                try await controller.goToSlide(invalid)
                throw CheckFailure(description: "Invalid local target succeeded")
            } catch is CheckFailure { throw CheckFailure(description: "Invalid local target succeeded") }
            catch { try check(controller.isConnected && !controller.isBusy, "Invalid local target sends nothing and keeps connection") }
        }
        try await peer.expectQuiet()
        controller.disconnect()
        try await peer.expectClosed()
        try check(controller.currentSlidePosition == nil && controller.totalSlides == nil, "Disconnected metadata is unavailable")

        for failure in ["wrong-position", "unchanged-id", "changed-page", "unexpected-ended", "remote-error"] {
            let (badPeer, badSession) = try await pair(controller, socket: socket, snapshot: initial)
            let movement = Task { try await controller.goToSlide(3) }
            let command = try await badPeer.message()
            var badSnapshot = initial
            badSnapshot.position = 3
            badSnapshot.slideID = "slide-three"
            if failure == "wrong-position" { badSnapshot.position = 2 }
            if failure == "unchanged-id" { badSnapshot.slideID = initial.slideID }
            if failure == "changed-page" { badSnapshot.pageID = "another-page" }
            try badPeer.send(BridgeMessage(type: .result, session: badSession, requestID: command.requestID,
                                          snapshot: badSnapshot, error: failure == "remote-error" ? "Slide changed manually" : nil,
                                          ended: failure == "unexpected-ended" ? true : nil))
            do {
                try await movement.value
                throw CheckFailure(description: "Unverified jump succeeded: \(failure)")
            } catch is CheckFailure { throw CheckFailure(description: "Unverified jump succeeded: \(failure)") }
            catch { try check(!controller.isConnected && !controller.isBusy, "Unverified jump disconnects: \(failure)") }
            try await badPeer.expectClosed()
        }

        let (canceledPeer, canceledSession) = try await pair(controller, socket: socket, snapshot: initial)
        let canceled = Task { try await controller.goToSlide(3) }
        let canceledCommand = try await canceledPeer.message()
        canceled.cancel()
        do {
            try await canceled.value
            throw CheckFailure(description: "Canceled jump succeeded")
        } catch is CheckFailure { throw CheckFailure(description: "Canceled jump succeeded") }
        catch { try check(!controller.isConnected && !controller.isBusy, "Canceled jump disconnects without retry") }
        var lateSnapshot = initial
        lateSnapshot.position = 3
        lateSnapshot.slideID = "slide-three"
        try? canceledPeer.send(BridgeMessage(type: .result, session: canceledSession, requestID: canceledCommand.requestID, snapshot: lateSnapshot))
        try await canceledPeer.expectClosed()
        try await Task.sleep(for: .milliseconds(30))
        try check(controller.currentSlidePosition == nil && !controller.isConnected, "Late jump acknowledgement cannot restore canceled connection")
    }

    @MainActor
    private static func positionRefreshChecks(_ controller: BrowserPresentationController, socket: String, initial: SlideSnapshot) async throws {
        do {
            _ = try await controller.refreshPosition()
            throw CheckFailure(description: "Disconnected position refresh succeeded")
        } catch is CheckFailure { throw CheckFailure(description: "Disconnected position refresh succeeded") }
        catch { try check(!controller.isConnected && !controller.isBusy, "Disconnected refresh never creates a connection") }

        let (peer, session) = try await pair(controller, socket: socket, snapshot: initial)
        var expected = initial
        for position in [3, 1] {
            let refresh = Task { try await controller.refreshPosition() }
            let command = try await peer.message()
            try check(command.operation == .status && command.targetPosition == nil && command.snapshot == expected,
                      "Position refresh sends a read-only status request using the paired presentation")
            try check(controller.currentSlidePosition == expected.position && controller.isBusy,
                      "Displayed position stays unchanged until refresh is acknowledged")
            do {
                _ = try await controller.refreshPosition()
                throw CheckFailure(description: "Concurrent refresh succeeded")
            } catch is CheckFailure { throw CheckFailure(description: "Concurrent refresh succeeded") }
            catch { try check(controller.isConnected && controller.isBusy, "Busy refresh is rejected without replacing the pending request") }
            try await peer.expectQuiet()
            var latest = initial
            latest.position = position
            latest.slideID = position == 1 ? "slide-one" : "slide-three"
            try peer.send(BridgeMessage(type: .result, session: session, requestID: command.requestID, snapshot: latest))
            let refreshed = try await refresh.value
            try check(refreshed == position && controller.currentSlidePosition == position && !controller.isBusy && controller.isConnected,
                      "Manual browser navigation refreshes the known position without moving the deck")
            try check(controller.status.contains("slide \(position) of 3"), "Refresh updates visible slide status")
            try await peer.expectQuiet()
            expected = latest
        }
        controller.disconnect()
        try await peer.expectClosed()

        for failure in ["changed-deck", "changed-page", "changed-total", "unexpected-ended", "remote-error"] {
            let (badPeer, badSession) = try await pair(controller, socket: socket, snapshot: initial)
            let refresh = Task { try await controller.refreshPosition() }
            let command = try await badPeer.message()
            var changed = initial
            changed.position = 2
            changed.slideID = "slide-two"
            if failure == "changed-deck" { changed.deckID = "different-deck" }
            if failure == "changed-page" { changed.pageID = "different-page" }
            if failure == "changed-total" { changed.total = 4 }
            try badPeer.send(BridgeMessage(type: .result, session: badSession, requestID: command.requestID,
                                          snapshot: changed, error: failure == "remote-error" ? "Synthetic refresh failure" : nil,
                                          ended: failure == "unexpected-ended" ? true : nil))
            do {
                _ = try await refresh.value
                throw CheckFailure(description: "Unverified refresh succeeded: \(failure)")
            } catch is CheckFailure { throw CheckFailure(description: "Unverified refresh succeeded: \(failure)") }
            catch { try check(!controller.isConnected && !controller.isBusy && controller.currentSlidePosition == nil,
                              "Unverified refresh disconnects without accepting position: \(failure)") }
            try await badPeer.expectClosed()
        }

        let (canceledPeer, canceledSession) = try await pair(controller, socket: socket, snapshot: initial)
        let canceled = Task { try await controller.refreshPosition() }
        let canceledCommand = try await canceledPeer.message()
        canceled.cancel()
        do {
            _ = try await canceled.value
            throw CheckFailure(description: "Canceled refresh succeeded")
        } catch is CheckFailure { throw CheckFailure(description: "Canceled refresh succeeded") }
        catch { try check(!controller.isConnected && !controller.isBusy, "Canceled refresh disconnects without retry") }
        var lateSnapshot = initial
        lateSnapshot.position = 3
        lateSnapshot.slideID = "slide-three"
        try? canceledPeer.send(BridgeMessage(type: .result, session: canceledSession, requestID: canceledCommand.requestID, snapshot: lateSnapshot))
        try await canceledPeer.expectClosed()
        try await Task.sleep(for: .milliseconds(30))
        try check(controller.currentSlidePosition == nil && !controller.isConnected, "Late refresh cannot restore a canceled connection")
    }

    @MainActor
    static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "Timed out waiting for controller")
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private final class Peer {
    let fd: Int32
    private var decoder = BridgeFrameDecoder()
    private var messages: [BridgeMessage] = []

    init(socket: String) throws { fd = try UnixBridge.connect(path: socket) }
    deinit { Darwin.close(fd) }
    func send(_ message: BridgeMessage) throws { try UnixBridge.write(BridgeFraming.encode(message), to: fd) }

    // nil = no new data, false = closed, true = data received.
    private func read() throws -> Bool? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return nil }
        guard count >= 0 else { throw CheckFailure(description: "Peer read failed") }
        if count == 0 { return false }
        messages += try decoder.append(Data(bytes.prefix(count)))
        return true
    }

    func message() async throws -> BridgeMessage {
        for _ in 0..<200 {
            if !messages.isEmpty { return messages.removeFirst() }
            if try read() == false { throw CheckFailure(description: "Peer closed before command") }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "No command received")
    }

    func expectQuiet() async throws {
        for _ in 0..<10 {
            if try read() == false { throw CheckFailure(description: "Unexpected disconnect") }
            guard messages.isEmpty else { throw CheckFailure(description: "Pairing emitted an extra command") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func expectClosed() async throws {
        for _ in 0..<200 {
            guard messages.isEmpty else { throw CheckFailure(description: "Unexpected command before disconnect") }
            if try read() == false { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "Peer did not disconnect")
    }
}
