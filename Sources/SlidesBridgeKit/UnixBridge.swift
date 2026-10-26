import Darwin
import Foundation

public enum UnixBridge {
    public static func prepareDirectory(_ directory: URL = SlidesBridgeIdentity.directory) throws {
        // Only our own two directories are created or hardened. Never follow a
        // symlink into another location or change Library's shared permissions.
        for url in [directory.deletingLastPathComponent(), directory] {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard errno == ENOENT, mkdir(url.path, 0o700) == 0 else { throw systemError() }
                guard lstat(url.path, &info) == 0 else { throw systemError() }
            }
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw SlidesBridgeError.unsafePath }
            guard chmod(url.path, 0o700) == 0 else { throw systemError() }
        }
    }

    public static func connect(path: String = SlidesBridgeIdentity.socketPath) throws -> Int32 {
        try validateSocket(path)
        let fd = try makeSocket()
        do {
            try setNonblocking(fd)
            var address = try socketAddress(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw systemError() }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&descriptor, 1, 2_000) > 0 else { throw SlidesBridgeError.timeout }
                var code: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: code))
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0, code == 0 else {
                    throw SlidesBridgeError.disconnected
                }
            }
            try checkPeer(fd)
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    public static func write(_ data: Data, to fd: Int32, timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw SlidesBridgeError.timeout }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining * 1_000, 2_000)))
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else { throw systemError() }
                if ready == 0 { throw SlidesBridgeError.timeout }
                guard descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw SlidesBridgeError.disconnected }
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EAGAIN || errno == EINTR { continue }
                guard written > 0 else { throw SlidesBridgeError.disconnected }
                offset += written
            }
        }
    }

    public static func validateSocket(_ path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        for url in [directory.deletingLastPathComponent(), directory] {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw SlidesBridgeError.unsafePath }
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o077 == 0 else { throw SlidesBridgeError.unsafePath }
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError() }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(fd); throw systemError() }
        return fd
    }
    static func setNonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw systemError() }
    }
    static func checkPeer(_ fd: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw SlidesBridgeError.unsafePath }
    }
    static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SlidesBridgeError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    static func systemError() -> SlidesBridgeError { .system(String(cString: strerror(errno))) }
}

/// Single-client transport. The app decides when to accept a candidate deck.
/// Every file descriptor, decoder and write is confined to one serial queue.
public final class UnixBridgeServer: @unchecked Sendable {
    public enum Event: Sendable {
        case message(UUID, BridgeMessage)
        case closed(UUID, String?)
        case ambiguous
    }
    private final class Client {
        let id = UUID()
        let fd: Int32
        let source: DispatchSourceRead
        var decoder = BridgeFrameDecoder()
        var receivedHello = false
        var deadline: Date? = Date().addingTimeInterval(4)
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }
    private let queue = DispatchQueue(label: "com.biblejustin.localprompt.slides.socket")
    private let key = DispatchSpecificKey<UInt8>()
    private let path: String
    private let onEvent: @Sendable (Event) -> Void
    private var listener: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var client: Client?
    private var boundIdentity: (dev_t, ino_t)?
    private var lockFD: Int32 = -1

    public init(path: String = SlidesBridgeIdentity.socketPath, onEvent: @escaping @Sendable (Event) -> Void) {
        self.path = path; self.onEvent = onEvent
        queue.setSpecific(key: key, value: 1)
    }
    deinit { stop() }

    public func start() throws {
        try queue.sync {
            guard listener == nil else { return }
            try UnixBridge.prepareDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
            try acquireLock()
            defer { if listener == nil { releaseLock() } }
            var existing = stat()
            if lstat(path, &existing) == 0 {
                try UnixBridge.validateSocket(path)
                // Holding our exclusive lock proves another bridge cannot own
                // this stale socket. Probing it would disrupt a live session.
                var current = stat()
                guard lstat(path, &current) == 0, current.st_dev == existing.st_dev, current.st_ino == existing.st_ino,
                      unlink(path) == 0 else { throw SlidesBridgeError.unsafePath }
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
                guard chmod(path, 0o600) == 0, listen(fd, 2) == 0 else { throw UnixBridge.systemError() }
                try UnixBridge.setNonblocking(fd)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptClient(fd) }
                source.setCancelHandler { Darwin.close(fd) }
                listener = source
                source.resume()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self, let client = self.client, let deadline = client.deadline, deadline < Date() else { return }
                    self.closeClient(reason: SlidesBridgeError.timeout.localizedDescription)
                }
                self.timer = timer
                timer.resume()
            } catch { Darwin.close(fd); removeOwnSocket(); throw error }
        }
    }

    public func send(_ message: BridgeMessage, to id: UUID, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self, let client = self.client, client.id == id else { completion(SlidesBridgeError.disconnected); return }
            do { try UnixBridge.write(BridgeFraming.encode(message), to: client.fd); completion(nil) }
            catch { completion(error); self.closeClient(reason: error.localizedDescription) }
        }
    }
    public func disconnect() { queue.async { [weak self] in self?.closeClient(reason: nil) } }
    public func stop() {
        let work = {
            self.closeClient(reason: nil)
            self.timer?.cancel(); self.timer = nil
            self.listener?.cancel(); self.listener = nil
            self.removeOwnSocket()
            self.releaseLock()
        }
        if DispatchQueue.getSpecific(key: key) != nil { work() } else { queue.sync(execute: work) }
    }

    private func acceptClient(_ listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            if fd < 0 { return }
            do {
                try UnixBridge.checkPeer(fd)
                try UnixBridge.setNonblocking(fd)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                var enabled: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else { throw UnixBridge.systemError() }
                guard client == nil else {
                    Darwin.close(fd); closeClient(reason: "More than one browser slide connection attempted.")
                    onEvent(.ambiguous); continue
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                let client = Client(fd: fd, source: source)
                self.client = client
                source.setEventHandler { [weak self, weak client] in
                    guard let self, let client else { return }
                    self.readClient(client)
                }
                source.setCancelHandler { Darwin.close(fd) }
                source.resume()
            } catch { Darwin.close(fd) }
        }
    }

    private func readClient(_ current: Client) {
        guard client === current else { return }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(current.fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            guard count > 0 else { closeClient(reason: nil); return }
            do {
                let messages = try current.decoder.append(Data(bytes.prefix(count)))
                for message in messages {
                    if !current.receivedHello {
                        guard message.type == .hello else { throw SlidesBridgeError.invalidMessage }
                        current.receivedHello = true
                    } else {
                        guard message.type == .result || message.type == .disconnect else { throw SlidesBridgeError.invalidMessage }
                    }
                    onEvent(.message(current.id, message))
                }
                if current.decoder.hasPartialFrame {
                    if current.deadline == nil { current.deadline = Date().addingTimeInterval(4) }
                } else { current.deadline = current.receivedHello ? nil : Date().addingTimeInterval(4) }
            } catch { closeClient(reason: error.localizedDescription); return }
        }
    }
    private func closeClient(reason: String?) {
        guard let current = client else { return }
        client = nil
        shutdown(current.fd, SHUT_RDWR)
        current.source.cancel()
        onEvent(.closed(current.id, reason))
    }
    private func removeOwnSocket() {
        guard let identity = boundIdentity else { return }
        var info = stat()
        if lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
           info.st_dev == identity.0, info.st_ino == identity.1 { _ = unlink(path) }
        boundIdentity = nil
    }
    private func acquireLock() throws {
        let fd = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SlidesBridgeError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { Darwin.close(fd); throw SlidesBridgeError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw SlidesBridgeError.alreadyRunning }
        lockFD = fd
    }
    private func releaseLock() {
        guard lockFD >= 0 else { return }
        _ = flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
        lockFD = -1
    }
}
