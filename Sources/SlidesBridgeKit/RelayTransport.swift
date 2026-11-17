import Darwin
import Foundation

// Safari has no long-lived native host. Its extension handler (an app
// extension) wakes for each message, hands that one frame to LocalPrompt over
// this short-lived socket, and waits for a one-byte answer.

extension SlidesBridgeIdentity {
    public static var relaySocketPath: String {
        directory.appendingPathComponent(groupContainer == nil ? "relay.sock" : "r.sock").path
    }
}

extension UnixBridge {
    /// Sends one validated frame to the relay and returns whether LocalPrompt
    /// accepted it.
    public static func sendOnce(_ message: BridgeMessage, path: String = SlidesBridgeIdentity.relaySocketPath,
                                timeout: TimeInterval = 3) throws -> Bool {
        let frame = try BridgeFraming.encode(message)
        let fd = try connect(path: path)
        defer { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        try write(frame, to: fd, timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        var reply: UInt8 = 0
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SlidesBridgeError.timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1_000, 2_000)))
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw systemError() }
            if ready == 0 { continue }
            let count = Darwin.read(fd, &reply, 1)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count == 1 else { throw SlidesBridgeError.disconnected }
            return reply == 1
        }
    }
}

/// Accepts one frame per connection from LocalPrompt's Safari extension
/// handler. `handle` runs on `queue` and decides the one-byte answer.
public final class UnixRelayListener: @unchecked Sendable {
    private let path: String
    private let queue: DispatchQueue
    private let handle: (BridgeMessage) -> Bool
    private var listener: DispatchSourceRead?
    private var boundIdentity: (dev_t, ino_t)?
    private var lockFD: Int32 = -1

    public init(path: String = SlidesBridgeIdentity.relaySocketPath, queue: DispatchQueue,
                handle: @escaping (BridgeMessage) -> Bool) {
        self.path = path; self.queue = queue; self.handle = handle
    }
    deinit { stop() }

    public func start() throws {
        guard listener == nil else { return }
        try UnixBridge.prepareDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        let lock = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw SlidesBridgeError.unsafePath }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lock); throw SlidesBridgeError.alreadyRunning }
        lockFD = lock
        do {
            var existing = stat()
            if lstat(path, &existing) == 0 {
                // Our lock proves no other relay owns this leftover socket.
                guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else {
                    throw SlidesBridgeError.unsafePath
                }
            } else if errno != ENOENT { throw UnixBridge.systemError() }
            let fd = try UnixBridge.makeSocket()
            do {
                var address = try UnixBridge.socketAddress(path)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard result == 0 else { throw UnixBridge.systemError() }
                var info = stat()
                guard lstat(path, &info) == 0 else { throw UnixBridge.systemError() }
                boundIdentity = (info.st_dev, info.st_ino)
                guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw UnixBridge.systemError() }
                try UnixBridge.setNonblocking(fd)
            } catch { Darwin.close(fd); throw error }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients(fd) }
            source.setCancelHandler { Darwin.close(fd) }
            listener = source
            source.resume()
        } catch {
            removeOwnSocket(); releaseLock()
            throw error
        }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        removeOwnSocket()
        releaseLock()
    }

    private func acceptClients(_ listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            if fd < 0 { return }
            serve(fd)
        }
    }

    private func serve(_ fd: Int32) {
        defer { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        var accepted = false
        do {
            try UnixBridge.checkPeer(fd)
            try UnixBridge.setNonblocking(fd)
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
            var decoder = BridgeFrameDecoder()
            var messages: [BridgeMessage] = []
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let deadline = Date().addingTimeInterval(2)
            while messages.isEmpty {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw SlidesBridgeError.timeout }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(remaining * 1_000))
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { throw SlidesBridgeError.timeout }
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count < 0, errno == EAGAIN || errno == EINTR { continue }
                guard count > 0 else { throw SlidesBridgeError.disconnected }
                messages = try decoder.append(Data(bytes.prefix(count)))
            }
            guard messages.count == 1, !decoder.hasPartialFrame else { throw SlidesBridgeError.invalidMessage }
            accepted = handle(messages[0])
        } catch { accepted = false }
        try? UnixBridge.write(Data([accepted ? 1 : 0]), to: fd, timeout: 1)
    }

    private func removeOwnSocket() {
        guard let identity = boundIdentity else { return }
        var info = stat()
        if lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
           info.st_dev == identity.0, info.st_ino == identity.1 { _ = unlink(path) }
        boundIdentity = nil
    }

    private func releaseLock() {
        guard lockFD >= 0 else { return }
        _ = flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
        lockFD = -1
    }
}
