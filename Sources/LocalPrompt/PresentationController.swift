import AppKit
import Carbon
import Combine

/// Controls an explicitly connected, already-running PowerPoint slideshow.
/// Only fixed AppleScript handlers run; deck names are typed event arguments.
@MainActor
final class PresentationController: ObservableObject {
    @Published private(set) var status = "Slides disconnected"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false

    private nonisolated static let bundleID = "com.microsoft.Powerpoint"
    private let queue = DispatchQueue(label: "com.biblejustin.localprompt.presentation")
    private var connection: Connection?
    private var generation = UUID()
    private var operation: OperationToken?

    func connect() async {
        guard !isBusy else { return }
        disconnect()
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        guard applications.count == 1, let application = applications.first,
              !application.isTerminated else {
            fail("Open PowerPoint and start one slideshow, then connect again.")
            return
        }
        let request = generation
        let token = OperationToken()
        operation = token
        isBusy = true
        status = "Connecting to PowerPoint…"
        defer { isBusy = false; if operation === token { operation = nil } }
        do {
            let snapshot = try await perform(.connect, processID: application.processIdentifier, token: token)
            guard generation == request else { return }
            guard !Task.isCancelled, !application.isTerminated else {
                disconnect()
                return
            }
            guard case .ready(let show) = snapshot else { throw ControlError.invalidResponse }
            connection = Connection(application: application, show: show)
            isConnected = true
            errorMessage = nil
            status = "PowerPoint · \(show.name) · slide \(show.slideIndex)"
        } catch {
            guard generation == request else { return }
            fail(error.localizedDescription)
        }
    }

    /// Sends exactly one native next-slide command. No activation, key events,
    /// animation loops, or automatic retries after a possibly delivered command.
    func advance() async throws {
        guard !isBusy else { throw ControlError.busy }
        guard let connection, isConnected, !connection.application.isTerminated else {
            let error = ControlError.notConnected
            fail(error.localizedDescription)
            throw error
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).count == 1 else {
            let error = ControlError.ambiguousApplication
            fail(error.localizedDescription)
            throw error
        }
        let request = generation
        let token = OperationToken()
        operation = token
        isBusy = true
        defer { isBusy = false; if operation === token { operation = nil } }
        do {
            let response = try await perform(.advance(connection.show),
                                             processID: connection.application.processIdentifier, token: token)
            guard generation == request else { throw ControlError.disconnectedDuringRequest }
            switch response {
            case .ready(let show):
                self.connection = Connection(application: connection.application, show: show)
                status = "PowerPoint · \(show.name) · slide \(show.slideIndex)"
            case .ended:
                self.connection = nil
                isConnected = false
                status = "Final PowerPoint slide kept on screen"
            }
            errorMessage = nil
        } catch {
            if generation == request { fail(error.localizedDescription) }
            throw error
        }
    }

    func disconnect() {
        operation?.cancel()
        operation = nil
        generation = UUID()
        connection = nil
        isConnected = false
        errorMessage = nil
        status = "Slides disconnected"
    }

    func clearError() { errorMessage = nil }

    private func fail(_ message: String) {
        connection = nil
        isConnected = false
        errorMessage = message
        status = "Slide control paused"
    }

    private struct Connection {
        let application: NSRunningApplication
        let show: Show
    }

    private struct Show: Sendable {
        let windowID: String
        let fullName: String
        let name: String
        let position: Int32
        let slideIndex: Int32
    }

    private enum Response: Sendable { case ready(Show), ended }
    private enum Request: Sendable { case connect, advance(Show) }

    private final class OperationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private func perform(_ request: Request, processID: pid_t, token: OperationToken) async throws -> Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try Self.execute(request, processID: processID, token: token)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    private nonisolated static func execute(_ request: Request, processID: pid_t, token: OperationToken) throws -> Response {
        guard !token.isCancelled else { throw ControlError.disconnectedDuringRequest }
        guard let script = NSAppleScript(source: scriptSource) else { throw ControlError.invalidScript }
        var scriptError: NSDictionary?
        guard script.compileAndReturnError(&scriptError) else { throw ControlError(details: scriptError) }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let arguments = NSAppleEventDescriptor.list()
        let handler: String
        switch request {
        case .connect:
            handler = "connectshow"
        case .advance(let show):
            handler = "advanceshow"
            arguments.insert(NSAppleEventDescriptor(string: show.windowID), at: 1)
            arguments.insert(NSAppleEventDescriptor(string: show.fullName), at: 2)
            arguments.insert(NSAppleEventDescriptor(int32: show.position), at: 3)
            arguments.insert(NSAppleEventDescriptor(int32: show.slideIndex), at: 4)
        }
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        guard !token.isCancelled else { throw ControlError.disconnectedDuringRequest }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard applications.count == 1, applications.first?.processIdentifier == processID,
              applications.first?.isTerminated == false else { throw ControlError.notConnected }
        let result = script.executeAppleEvent(event, error: &scriptError)
        if let scriptError { throw ControlError(details: scriptError) }
        if result.atIndex(1)?.stringValue == "ended" { return .ended }
        guard result.numberOfItems == 6,
              result.atIndex(1)?.stringValue == "ready",
              let windowID = result.atIndex(2)?.stringValue,
              let fullName = result.atIndex(3)?.stringValue,
              let name = result.atIndex(4)?.stringValue,
              let position = result.atIndex(5)?.int32Value,
              let slideIndex = result.atIndex(6)?.int32Value,
              !windowID.isEmpty, !fullName.isEmpty, position > 0, slideIndex > 0 else {
            throw ControlError.invalidResponse
        }
        return .ready(Show(windowID: windowID, fullName: fullName, name: name,
                           position: position, slideIndex: slideIndex))
    }

    private enum ControlError: LocalizedError {
        case busy, notConnected, ambiguousApplication, disconnectedDuringRequest, invalidScript, invalidResponse
        case script(code: Int?, message: String?)

        init(details: NSDictionary?) {
            self = .script(code: (details?[NSAppleScript.errorNumber] as? NSNumber)?.intValue,
                           message: details?[NSAppleScript.errorMessage] as? String)
        }

        var errorDescription: String? {
            switch self {
            case .busy: return "A slide command is already in progress."
            case .notConnected: return "Connect to the running PowerPoint slideshow before sending a cue."
            case .ambiguousApplication: return "More than one PowerPoint instance is running. Close extra copies, then reconnect."
            case .disconnectedDuringRequest: return "Slide connection changed during the command. Check the slide before reconnecting."
            case .invalidScript: return "PowerPoint slide control could not be prepared."
            case .invalidResponse: return "PowerPoint returned an unexpected response. Check the slide before reconnecting."
            case .script(let number, let message):
                if number == -1743 {
                    return "Allow LocalPrompt to control PowerPoint in System Settings → Privacy & Security → Automation, then connect again."
                }
                if number == -1712 {
                    return "PowerPoint did not respond in time. The slide may have changed; check it before reconnecting. No retry was sent."
                }
                return message ?? "PowerPoint slide control failed. Check the slide before reconnecting."
            }
        }
    }

    private nonisolated static let scriptSource = """
    on connectShow()
        with timeout of 5 seconds
            tell application id "com.microsoft.Powerpoint"
                if (count of slide show windows) is not 1 then error "Start exactly one PowerPoint slideshow, then connect again." number 1001
                set showWindow to slide show window 1
                set showView to slideshow view of showWindow
                my requireControllableState(showView)
                if is named show of showView then error "Custom PowerPoint shows are not supported yet. Use an ordinary slideshow or slide range." number 1007
                set deck to presentation of showWindow
                return {"ready", (id of showWindow) as text, full name of deck, name of deck, current show position of showView, slide index of (slide of showView)}
            end tell
        end timeout
    end connectShow

    on advanceShow(expectedWindowID, expectedFullName, expectedPosition, expectedSlideIndex)
        with timeout of 5 seconds
            tell application id "com.microsoft.Powerpoint"
                if (count of slide show windows) is not 1 then error "The connected slideshow is no longer available. Check PowerPoint and reconnect." number 1001
                set showWindow to slide show window 1
                set deck to presentation of showWindow
                if ((id of showWindow) as text) is not expectedWindowID or (full name of deck) is not expectedFullName then error "The PowerPoint presentation changed. Connect again before sending cues." number 1003
                set showView to slideshow view of showWindow
                my requireControllableState(showView)
                if (current show position of showView) is not expectedPosition or (slide index of (slide of showView)) is not expectedSlideIndex then error "PowerPoint moved outside LocalPrompt. Check the slide and reconnect to resynchronize." number 1004
                if is named show of showView then error "Custom PowerPoint shows are not supported yet. Use an ordinary slideshow or slide range." number 1007
                set showSettings to slide show settings of deck
                if (range type of showSettings) is slide show range named slideshow then error "Custom PowerPoint shows are not supported yet. Use an ordinary slideshow or slide range." number 1007
                set lastSlideIndex to count of slides of deck
                if (range type of showSettings) is slide show range then set lastSlideIndex to ending slide of showSettings
                set nextSlideIndex to expectedSlideIndex + 1
                set scanDeadline to (current date) + 10
                repeat while nextSlideIndex is less than or equal to lastSlideIndex
                    if (current date) is greater than scanDeadline then error "PowerPoint slide validation took too long. No advance was sent. Reconnect before continuing." number 1008
                    if (hidden of slide show transition of slide nextSlideIndex of deck) is false then exit repeat
                    set nextSlideIndex to nextSlideIndex + 1
                end repeat
                if nextSlideIndex is greater than lastSlideIndex then return {"ended"}
                if (current date) is greater than scanDeadline then error "PowerPoint slide validation took too long. No advance was sent. Reconnect before continuing." number 1008
                go to next slide showView
                if (count of slide show windows) is 0 then error "The slideshow ended during the cue. Check PowerPoint before reconnecting." number 1005
                if (count of slide show windows) is not 1 then error "PowerPoint changed windows during the cue. Check the slide before reconnecting." number 1005
                set afterWindow to slide show window 1
                if ((id of afterWindow) as text) is not expectedWindowID or (full name of presentation of afterWindow) is not expectedFullName then error "PowerPoint changed presentations during the cue. Check the slide before reconnecting." number 1005
                set afterView to slideshow view of afterWindow
                my requireControllableState(afterView)
                set afterPosition to current show position of afterView
                set afterSlideIndex to slide index of (slide of afterView)
                if afterSlideIndex is not nextSlideIndex or afterPosition is expectedPosition then error "PowerPoint did not reach the expected next slide. Check the slide before reconnecting; no retry was sent." number 1006
                return {"ready", expectedWindowID, expectedFullName, name of deck, afterPosition, afterSlideIndex}
            end tell
        end timeout
    end advanceShow

    on requireControllableState(showView)
        with timeout of 5 seconds
            tell application id "com.microsoft.Powerpoint"
                set showState to slide state of showView
                if showState is slide show state running or showState is slide show state paused then return
                set stateDescription to "unknown"
                if showState is slide show state black screen then set stateDescription to "black screen"
                if showState is slide show state white screen then set stateDescription to "white screen"
                if showState is slide show state done then set stateDescription to "done"
                if stateDescription is "unknown" then
                    try
                        set stateDescription to showState as text
                    end try
                end if
                error "PowerPoint slideshow is not ready (reported state: " & stateDescription & "). Check PowerPoint and reconnect; no retry was sent." number 1002
            end tell
        end timeout
    end requireControllableState
    """
}
