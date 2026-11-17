import Combine
import Foundation
import PromptCore

// These collaborators expose acknowledgements as test-controlled events. The
// real AppModel and PromptCore decide all word positions, cue state and routing.
@MainActor
final class SpeechController: ObservableObject {
    @Published var isRunning = false
    @Published var isPreparing = false
    @Published var transcript = ""
    @Published var errorMessage: String?
    private(set) var startCalls = 0
    func start() async { startCalls += 1; transcript = ""; isRunning = true }
    func stop() { isRunning = false; isPreparing = false }
}

@MainActor
final class SlidePresentationController: ObservableObject {
    enum Target { case brave, powerpoint }
    @Published var target: Target = .brave
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    var totalSlides: Int? = 6
    var currentSlidePosition: Int? = 1
    var supportsManualSync: Bool { target == .brave }
    let browser = BrowserStub()
    private(set) var goToRequests: [Int] = []
    private(set) var advanceCalls = 0
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var refreshCalls = 0
    var connectSucceeds = true
    private var pendingGoTo: (Int, CheckedContinuation<Void, Error>)?
    var hasPendingGoTo: Bool { pendingGoTo != nil }
    private var pendingRefresh: CheckedContinuation<Int, Error>?
    var hasPendingRefresh: Bool { pendingRefresh != nil }

    func connect() async {
        connectCalls += 1
        isConnected = connectSucceeds
        errorMessage = connectSucceeds ? nil : "Synthetic pairing failure"
    }
    func goToSlide(_ position: Int) async throws {
        guard isConnected, pendingGoTo == nil else { throw SyntheticFailure.disconnected }
        goToRequests.append(position)
        isBusy = true
        defer { isBusy = false }
        try await withCheckedThrowingContinuation { pendingGoTo = (position, $0) }
    }
    func finishGoTo(success: Bool = true) {
        guard let pending = pendingGoTo else { preconditionFailure("No pending slide selection") }
        pendingGoTo = nil
        if success {
            // A dispatched browser operation may finish after cancellation.
            // Let the real model decide whether to accept that late result.
            currentSlidePosition = pending.0
            pending.1.resume()
        } else { pending.1.resume(throwing: SyntheticFailure.rejected) }
    }
    func refreshPosition() async throws -> Int {
        guard isConnected, !isBusy, pendingRefresh == nil else { throw SyntheticFailure.disconnected }
        refreshCalls += 1
        isBusy = true
        defer { isBusy = false }
        return try await withCheckedThrowingContinuation { pendingRefresh = $0 }
    }
    func finishRefresh(at position: Int, success: Bool = true) {
        guard let pending = pendingRefresh else { preconditionFailure("No pending slide status request") }
        pendingRefresh = nil
        if success {
            currentSlidePosition = position
            pending.resume(returning: position)
        } else { pending.resume(throwing: SyntheticFailure.rejected) }
    }
    func advance() async throws {
        guard isConnected else { throw SyntheticFailure.disconnected }
        advanceCalls += 1
        currentSlidePosition = currentSlidePosition.map { $0 + 1 }
    }
    func disconnect() {
        disconnectCalls += 1
        isConnected = false
        isBusy = false
        errorMessage = nil
    }
}

@MainActor
final class BrowserStub {
    var onPairingRequested: (() -> String?)?
    func startListening() throws {}
    func stopListening() {}
}

@MainActor
final class ReadingActivity { func setActive(_ active: Bool) {} }

@MainActor
final class SermonLibraryController {
    let info: NoteLibrary
    var folderURL: URL?
    init(library: NoteLibrary, defaults: UserDefaults) { info = library }
    func update(_ library: NoteLibrary) {}
}

struct LinkedSermon: Codable {
    let name: String
    init(fileURL: URL, folderURL: URL) throws { name = fileURL.deletingPathExtension().lastPathComponent }
    func resolve() throws -> (file: URL, folder: URL) { throw SyntheticFailure.rejected }
}

enum SyntheticFailure: LocalizedError {
    case disconnected, rejected
    var errorDescription: String? { "Synthetic slide selection failure" }
}

/// All app reads and writes stay in this dictionary. Library collaborators above
/// never instantiate UserDefaults or touch bookmarks, folders, or browser state.
final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
