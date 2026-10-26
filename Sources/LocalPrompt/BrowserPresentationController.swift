import Combine
import Foundation
import SlidesBridgeKit

@MainActor
final class BrowserPresentationController: ObservableObject {
    @Published private(set) var status = "Brave slides disconnected"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var hasCandidate = false

    private struct Candidate {
        let clientID: UUID
        let session: String
        var snapshot: SlideSnapshot
    }
    private struct Pending {
        let requestID: Int
        let clientID: UUID
        let session: String
        let continuation: CheckedContinuation<BridgeMessage, Error>
        let timeout: Task<Void, Never>
    }
    private var candidate: Candidate?
    private var pending: Pending?
    private var nextRequestID = 1
    private var lastCompletedRequestID = 0
    private var generation = UUID()
    private lazy var server = UnixBridgeServer { [weak self] event in
        Task { @MainActor [weak self] in self?.receive(event) }
    }

    /// Only called after explicit slide-control setup. No listener at app launch.
    func startListening() throws { try server.start() }

    func connect() async {
        guard !isBusy else { return }
        errorMessage = nil
        let requestGeneration = generation
        do {
            try startListening()
            guard let candidate else {
                status = "Open your slideshow in Brave. Click the LocalPrompt extension to pair it, then Connect here."
                return
            }
            isBusy = true
            defer { if generation == requestGeneration { isBusy = false } }
            let result = try await request(.status, candidate: candidate)
            guard generation == requestGeneration else { return }
            let snapshot = try checkedSnapshot(result)
            guard snapshot.samePresentation(as: candidate.snapshot) else { throw BrowserError.presentationChanged }
            self.candidate?.snapshot = snapshot
            isConnected = true
            status = label(snapshot)
        } catch {
            if generation == requestGeneration, !Task.isCancelled { fail(error.localizedDescription) }
        }
    }

    func advance() async throws {
        guard !isBusy else { throw BrowserError.busy }
        guard isConnected, let candidate else { throw SlidesBridgeError.disconnected }
        isBusy = true
        let requestGeneration = generation
        defer { if generation == requestGeneration { isBusy = false } }
        do {
            let result = try await request(.advance, candidate: candidate)
            guard generation == requestGeneration else { throw SlidesBridgeError.disconnected }
            let snapshot = try checkedSnapshot(result)
            guard snapshot.samePresentation(as: candidate.snapshot) else { throw BrowserError.presentationChanged }
            if result.ended == true {
                guard candidate.snapshot.position == candidate.snapshot.total,
                      snapshot == candidate.snapshot else { throw BrowserError.unexpectedPosition }
                disconnect()
                status = "Final Google Slides slide kept on screen"
                return
            }
            guard snapshot.position == candidate.snapshot.position + 1,
                  snapshot.slideID != candidate.snapshot.slideID else { throw BrowserError.unexpectedPosition }
            self.candidate?.snapshot = snapshot
            status = label(snapshot)
        } catch {
            if generation == requestGeneration, !Task.isCancelled { fail(error.localizedDescription) }
            throw error
        }
    }

    func disconnect() {
        generation = UUID()
        finishPending(.failure(SlidesBridgeError.disconnected))
        candidate = nil
        hasCandidate = false
        isConnected = false
        isBusy = false
        errorMessage = nil
        status = "Brave slides disconnected"
        server.disconnect()
    }

    func stopListening() { disconnect(); server.stop() }

    private func request(_ operation: BridgeMessage.Operation, candidate: Candidate) async throws -> BridgeMessage {
        guard pending == nil, nextRequestID < 2_147_483_647 else { throw BrowserError.busy }
        let id = nextRequestID
        nextRequestID += 1
        let requestGeneration = generation
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard let self, self.pending?.requestID == id else { return }
                    self.fail(SlidesBridgeError.timeout.localizedDescription)
                }
                pending = Pending(requestID: id, clientID: candidate.clientID, session: candidate.session,
                                  continuation: continuation, timeout: timeout)
                let message = BridgeMessage(type: .command, session: candidate.session, requestID: id,
                                            operation: operation, snapshot: candidate.snapshot)
                server.send(message, to: candidate.clientID) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.pending?.requestID == id else { return }
                        self.fail(error.localizedDescription)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else { return }
                self.disconnect()
            }
        }
    }

    private func receive(_ event: UnixBridgeServer.Event) {
        switch event {
        case .ambiguous:
            fail("More than one browser slide connection appeared. Disconnect extra extension sessions, then reconnect.")
        case .closed(let clientID, let reason):
            guard candidate?.clientID == clientID || pending?.clientID == clientID else { return }
            fail(reason ?? SlidesBridgeError.disconnected.localizedDescription)
        case .message(let clientID, let message):
            switch message.type {
            case .hello:
                guard candidate == nil, let snapshot = message.snapshot else {
                    fail("Another slideshow tried to replace the connected deck. Reconnect explicitly.")
                    return
                }
                candidate = Candidate(clientID: clientID, session: message.session, snapshot: snapshot)
                hasCandidate = true
                status = "Brave found \(snapshot.title). Align notes and slide, then Connect."
            case .result:
                guard candidate?.clientID == clientID, candidate?.session == message.session else { return }
                guard let id = message.requestID else { fail(SlidesBridgeError.invalidMessage.localizedDescription); return }
                if id <= lastCompletedRequestID { return } // A duplicate acknowledgement cannot advance twice.
                guard let pending, id == pending.requestID, pending.clientID == clientID, pending.session == message.session else {
                    fail("Brave returned an unexpected command response. Check the slide and reconnect.")
                    return
                }
                if let error = message.error { finishPending(.failure(BrowserError.remote(error))) }
                else { finishPending(.success(message)) }
            case .disconnect:
                guard candidate?.clientID == clientID, candidate?.session == message.session else { return }
                fail(message.error ?? SlidesBridgeError.disconnected.localizedDescription)
            case .command:
                fail(SlidesBridgeError.invalidMessage.localizedDescription)
            }
        }
    }

    private func finishPending(_ result: Result<BridgeMessage, Error>) {
        guard let pending else { return }
        self.pending = nil
        lastCompletedRequestID = max(lastCompletedRequestID, pending.requestID)
        pending.timeout.cancel()
        pending.continuation.resume(with: result)
    }
    private func fail(_ message: String) {
        disconnect()
        status = "Brave slide control paused"
        errorMessage = message
    }
    private func checkedSnapshot(_ message: BridgeMessage) throws -> SlideSnapshot {
        if let error = message.error { throw BrowserError.remote(error) }
        guard let snapshot = message.snapshot else { throw SlidesBridgeError.invalidMessage }
        try snapshot.validate()
        return snapshot
    }
    private func label(_ snapshot: SlideSnapshot) -> String { "Brave · \(snapshot.title) · slide \(snapshot.position) of \(snapshot.total)" }
    private enum BrowserError: LocalizedError {
        case busy, presentationChanged, unexpectedPosition, remote(String)
        var errorDescription: String? {
            switch self {
            case .busy: return "A slide command is already in progress."
            case .presentationChanged: return "The Google Slides deck or browser page changed. Reconnect before sending cues."
            case .unexpectedPosition: return "Google Slides did not reach the expected next slide. Check it and reconnect; no retry was sent."
            case .remote(let message): return message
            }
        }
    }
}
