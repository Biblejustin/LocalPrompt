import Foundation
import SafariServices
import SlidesBridgeKit

/// Plays the browser helper's part for Safari, inside the app. Safari's
/// extension handler passes each frame from the extension to this relay; the
/// relay keeps one ordinary bridge connection per session, forwards frames to
/// it, and sends LocalPrompt's commands back to the extension.
final class SafariRelay: @unchecked Sendable {
    /// Only the App Store build carries the Safari extension. Its identifier is
    /// read from the bundle so a local test build's own identifier also works.
    static let extensionBundleIdentifier: String? = Bundle.main.builtInPlugInsURL
        .map { $0.appendingPathComponent("LocalPrompt Slides.appex") }
        .flatMap { Bundle(url: $0)?.bundleIdentifier }
    static var isBundled: Bool { extensionBundleIdentifier != nil }

    typealias Deliver = @Sendable ([String: Any]) -> Void
    private let queue = DispatchQueue(label: "com.biblejustin.localprompt.safari-relay")
    private let bridgePath: String
    private let deliver: Deliver
    private var listener: UnixRelayListener?
    private let listenPath: String
    private var bridgeFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var decoder = BridgeFrameDecoder()
    private var session: String?

    init(listenPath: String = SlidesBridgeIdentity.relaySocketPath,
         bridgePath: String = SlidesBridgeIdentity.socketPath,
         deliver: @escaping Deliver = SafariRelay.dispatchToSafari) {
        self.listenPath = listenPath
        self.bridgePath = bridgePath
        self.deliver = deliver
    }

    func start() throws {
        guard listener == nil else { return }
        let listener = UnixRelayListener(path: listenPath, queue: queue) { [weak self] message in
            self?.fromExtension(message) ?? false
        }
        try listener.start()
        self.listener = listener
    }

    func stop() {
        queue.sync {
            closeBridge(notify: false)
            listener?.stop()
            listener = nil
        }
    }

    @Sendable static func dispatchToSafari(_ frame: [String: Any]) {
        guard let extensionBundleIdentifier else { return }
        SFSafariApplication.dispatchMessage(withName: "frame", toExtensionWithIdentifier: extensionBundleIdentifier,
                                            userInfo: ["frame": frame]) { _ in }
    }

    // MARK: Relay queue

    private func fromExtension(_ message: BridgeMessage) -> Bool {
        switch message.type {
        case .hello:
            // A new pairing replaces any earlier Safari session, as a new
            // native host process does for Chrome and Brave.
            closeBridge(notify: false)
            do { bridgeFD = try UnixBridge.connect(path: bridgePath) } catch { return false }
            session = message.session
            startReading()
            return forward(message)
        case .result, .disconnect:
            guard bridgeFD >= 0, message.session == session else { return false }
            let delivered = forward(message)
            if message.type == .disconnect { closeBridge(notify: false) }
            return delivered
        case .command:
            return false
        }
    }

    private func forward(_ message: BridgeMessage) -> Bool {
        do {
            try UnixBridge.write(BridgeFraming.encode(message), to: bridgeFD)
            return true
        } catch {
            closeBridge(notify: true)
            return false
        }
    }

    private func startReading() {
        let fd = bridgeFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readBridge(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    private func readBridge(_ fd: Int32) {
        guard fd == bridgeFD else { return }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            guard count > 0 else { closeBridge(notify: true); return }
            do {
                for message in try decoder.append(Data(bytes.prefix(count))) {
                    guard message.session == session, message.type == .command || message.type == .disconnect else {
                        throw SlidesBridgeError.invalidMessage
                    }
                    deliver(try Self.dictionary(message))
                    if message.type == .disconnect { closeBridge(notify: false); return }
                }
            } catch { closeBridge(notify: true); return }
        }
    }

    /// Ends the current session. When LocalPrompt's side went away, the
    /// extension is told so it can show the same message Chrome users see.
    private func closeBridge(notify: Bool) {
        if notify, let session, let frame = try? Self.dictionary(BridgeMessage(type: .disconnect, session: session)) {
            deliver(frame)
        }
        if let source {
            shutdown(bridgeFD, SHUT_RDWR)
            source.cancel()
        } else if bridgeFD >= 0 {
            Darwin.close(bridgeFD)
        }
        source = nil
        bridgeFD = -1
        decoder = BridgeFrameDecoder()
        session = nil
    }

    private static func dictionary(_ message: BridgeMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlidesBridgeError.invalidMessage
        }
        return object
    }
}
