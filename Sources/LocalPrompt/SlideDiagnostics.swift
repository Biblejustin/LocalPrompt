import Darwin
import Foundation

/// Local troubleshooting history. The typed schema cannot accept note text,
/// speech, deck identifiers, URLs, paths, or remote error messages.
@MainActor
final class SlideDiagnostics {
    enum Event: String, Codable, CaseIterable {
        case appOpened, readingStarted, startBlocked, cueCrossed, cueSkipped
        case commandSent, commandConfirmed, commandFailed, disconnected, paired, notesOnly
        case requestTimedOut, remoteRejected, transportClosed, bridgeAmbiguous
    }

    static let shared = SlideDiagnostics()
    nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LocalPrompt", isDirectory: true)
            .appendingPathComponent("slides.jsonl")
    }

    private struct Entry: Encodable {
        let timestamp: Double
        let version: String
        let event: Event
        let position: Int?
        let cueCount: Int?
        let slide: Int?
        let total: Int?
    }

    private let destination: URL
    private let maximumBytes: Int
    private let version: String
    private let queue = DispatchQueue(label: "com.biblejustin.localprompt.slide-diagnostics", qos: .utility)

    init(destination: URL = SlideDiagnostics.defaultURL, maximumBytes: Int = 256 * 1024) {
        self.destination = destination
        self.maximumBytes = max(1024, maximumBytes)
        // Bundle metadata is reduced to a bounded numeric version, never copied
        // as an arbitrary string into a troubleshooting report.
        let candidate = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        version = candidate.count <= 32 && candidate.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil ? candidate : "0"
    }

    func record(_ event: Event, position: Int? = nil, cueCount: Int? = nil, slide: Int? = nil, total: Int? = nil) {
        let entry = Entry(timestamp: Date().timeIntervalSince1970, version: version, event: event,
                          position: nonnegative(position), cueCount: nonnegative(cueCount),
                          slide: nonnegative(slide), total: nonnegative(total))
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        let destination = destination
        let maximumBytes = maximumBytes
        queue.async { Self.append(line, to: destination, maximumBytes: maximumBytes) }
    }

    /// Best-effort flush when terminating or testing. A slow filesystem must
    /// never hold the app's main actor for more than one second.
    @discardableResult
    func flush(timeout: TimeInterval = 1) -> Bool {
        let completion = DispatchSemaphore(value: 0)
        queue.async { completion.signal() }
        let waitSeconds = timeout.isFinite ? min(max(timeout, 0), 1) : 1
        return completion.wait(timeout: .now() + waitSeconds) == .success
    }

    private func nonnegative(_ number: Int?) -> Int? {
        number.flatMap { $0 >= 0 ? $0 : nil }
    }

    nonisolated private static func append(_ line: Data, to destination: URL, maximumBytes: Int) {
        guard destination.isFileURL, line.count <= maximumBytes else { return }
        let directory = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let previous = name + ".previous"
        guard !name.isEmpty, name != ".", name != ".." else { return }
        // Refuse symlink directories before changing permissions or opening a file.
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700]) }
        catch { return }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              fchmod(directoryFD, 0o700) == 0 else { return }

        var fileFD = openLog(directoryFD, name)
        guard fileFD >= 0 else { return }
        defer { if fileFD >= 0 { close(fileFD) } }
        var info = stat()
        guard fstat(fileFD, &info) == 0 else { return }
        if info.st_size > maximumBytes - line.count {
            var previousInfo = stat()
            let result = fstatat(directoryFD, previous, &previousInfo, AT_SYMLINK_NOFOLLOW)
            guard result == 0 ? isPrivateRegularFile(previousInfo) : errno == ENOENT else { return }
            close(fileFD)
            fileFD = -1
            guard renameat(directoryFD, name, directoryFD, previous) == 0 else { return }
            fileFD = openLog(directoryFD, name)
            guard fileFD >= 0 else { return }
        }
        line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(fileFD, base.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    nonisolated private static func openLog(_ directoryFD: Int32, _ name: String) -> Int32 {
        let descriptor = openat(directoryFD, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return -1 }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isPrivateRegularFile(info), fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            return -1
        }
        return descriptor
    }

    nonisolated private static func isPrivateRegularFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1
    }
}
