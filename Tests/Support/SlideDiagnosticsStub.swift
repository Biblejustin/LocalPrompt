// Harnesses compile the real app controllers but must not write synthetic
// events into the user's troubleshooting history. The logger has its own tests.
@MainActor
final class SlideDiagnostics {
    enum Event {
        case appOpened, readingStarted, startBlocked, cueCrossed, cueSkipped
        case commandSent, commandConfirmed, commandFailed, disconnected, paired, notesOnly
        case requestTimedOut, remoteRejected, transportClosed, bridgeAmbiguous
    }
    static let shared = SlideDiagnostics()
    func record(_ event: Event, position: Int? = nil, cueCount: Int? = nil, slide: Int? = nil, total: Int? = nil) {}
    func flush() {}
}
