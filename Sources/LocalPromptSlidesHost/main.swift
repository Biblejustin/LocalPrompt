import Darwin
import Foundation
import SlidesBridgeKit

// Chromium supplies caller origin as its first argument. This executable has
// no UI, starts no applications, and never records document/script contents.
guard CommandLine.arguments.count == 2,
      CommandLine.arguments[1] == SlidesBridgeIdentity.extensionOrigin else {
    fputs("LocalPrompt slide bridge rejected caller.\n", stderr)
    exit(1)
}
signal(SIGPIPE, SIG_IGN)

do {
    let fd = try UnixBridge.connect()
    defer { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    // A slow/missing browser reader must not trap the helper after app exit.
    for descriptor in [STDIN_FILENO, STDOUT_FILENO] {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw SlidesBridgeError.disconnected }
    }
    var fromBrowser = BridgeFrameDecoder()
    var fromApp = BridgeFrameDecoder()
    var browserDeadline: Date? = Date().addingTimeInterval(4)
    var appDeadline: Date?
    var receivedHello = false
    var session: String?
    var bytes = [UInt8](repeating: 0, count: 4_096)
    while true {
        if let deadline = browserDeadline, deadline < Date() { throw SlidesBridgeError.timeout }
        if let deadline = appDeadline, deadline < Date() { throw SlidesBridgeError.timeout }
        var descriptors = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0), pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        let ready = poll(&descriptors, nfds_t(descriptors.count), 500)
        if ready < 0, errno == EINTR { continue }
        guard ready >= 0 else { throw SlidesBridgeError.disconnected }
        for index in 0..<descriptors.count {
            let events = descriptors[index].revents
            if events & Int16(POLLERR | POLLNVAL) != 0 { throw SlidesBridgeError.disconnected }
            guard events & Int16(POLLIN | POLLHUP) != 0 else { continue }
            let count = Darwin.read(descriptors[index].fd, &bytes, bytes.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { exit(0) }
            let data = Data(bytes.prefix(count))
            if index == 0 {
                for message in try fromBrowser.append(data) {
                    if !receivedHello {
                        guard message.type == .hello else { throw SlidesBridgeError.invalidMessage }
                        receivedHello = true; session = message.session
                    } else {
                        guard message.session == session, message.type == .result || message.type == .disconnect else { throw SlidesBridgeError.invalidMessage }
                    }
                    try UnixBridge.write(BridgeFraming.encode(message), to: fd)
                    if message.type == .disconnect { exit(0) }
                }
                if fromBrowser.hasPartialFrame {
                    if browserDeadline == nil { browserDeadline = Date().addingTimeInterval(4) }
                } else { browserDeadline = receivedHello ? nil : Date().addingTimeInterval(4) }
            } else {
                for message in try fromApp.append(data) {
                    guard message.session == session, message.type == .command || message.type == .disconnect else { throw SlidesBridgeError.invalidMessage }
                    try UnixBridge.write(BridgeFraming.encode(message), to: STDOUT_FILENO)
                    if message.type == .disconnect { exit(0) }
                }
                if fromApp.hasPartialFrame {
                    if appDeadline == nil { appDeadline = Date().addingTimeInterval(4) }
                } else { appDeadline = nil }
            }
        }
    }
} catch {
    // Error descriptions contain no deck text, URLs, tokens or script content.
    fputs("LocalPrompt slide bridge stopped: \(error.localizedDescription)\n", stderr)
    exit(1)
}
