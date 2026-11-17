import Darwin
import Foundation

// Synthetic events and disposable directories only. Never reads user logs.
@main
struct SlideDiagnosticsChecks {
    @MainActor
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw Failure(description: label) }
            checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("localprompt-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("logs/slides.jsonl")
        let log = SlideDiagnostics(destination: destination, maximumBytes: 1536)
        for event in SlideDiagnostics.Event.allCases {
            log.record(event, position: 42, cueCount: 3, slide: 2, total: 15)
        }
        log.flush()
        let previous = URL(fileURLWithPath: destination.path + ".previous")
        let permittedKeys: Set<String> = ["timestamp", "version", "event", "position", "cueCount", "slide", "total"]
        var events = [String]()
        for file in [previous, destination] {
            let data = try Data(contentsOf: file)
            try expect(data.count <= 1536, "Each rotated file stays within size limit")
            for line in data.split(separator: 0x0A) {
                let object = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
                try expect(Set(object.keys) == permittedKeys, "Only approved schema fields logged")
                try expect(object["position"] as? Int == 42 && object["slide"] as? Int == 2, "Numeric context preserved")
                events.append(object["event"] as! String)
            }
            var info = stat()
            _ = lstat(file.path, &info)
            try expect(info.st_mode & 0o777 == 0o600, "Log readable only by owner")
        }
        try expect(events == SlideDiagnostics.Event.allCases.map(\.rawValue), "Serial writes preserve event order across rotation")
        var directoryInfo = stat()
        _ = lstat(destination.deletingLastPathComponent().path, &directoryInfo)
        try expect(directoryInfo.st_mode & 0o777 == 0o700, "Log directory private")
        log.record(.startBlocked, position: -1, cueCount: -2)
        log.flush()
        let last = try String(contentsOf: destination, encoding: .utf8).split(separator: "\n").last!
        let entry = try JSONSerialization.jsonObject(with: Data(last.utf8)) as! [String: Any]
        try expect(entry["position"] == nil && entry["cueCount"] == nil, "Invalid numeric fields omitted")
        for _ in 0..<1000 { log.record(.commandSent, slide: 1, total: 15) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        try expect(files.count == 2, "Long sessions retain only current log plus one backup")
        for file in files { try expect(try Data(contentsOf: file).count <= 1536, "Long session file remains bounded") }

        let sentinel = root.appendingPathComponent("sentinel")
        try Data("private sentinel".utf8).write(to: sentinel)
        let links = root.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: false)
        let linkedFile = links.appendingPathComponent("slides.jsonl")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: sentinel)
        let linkedLog = SlideDiagnostics(destination: linkedFile)
        linkedLog.record(.appOpened); linkedLog.flush()
        try expect(try String(contentsOf: sentinel, encoding: .utf8) == "private sentinel", "Symlink file target untouched")

        let hardFile = links.appendingPathComponent("hard.jsonl")
        try FileManager.default.linkItem(at: sentinel, to: hardFile)
        let hardLog = SlideDiagnostics(destination: hardFile)
        hardLog.record(.appOpened); hardLog.flush()
        try expect(try String(contentsOf: sentinel, encoding: .utf8) == "private sentinel", "Hardlink file target untouched")

        let linkedDirectory = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: links)
        let directoryLog = SlideDiagnostics(destination: linkedDirectory.appendingPathComponent("new.jsonl"))
        directoryLog.record(.appOpened); directoryLog.flush()
        try expect(!FileManager.default.fileExists(atPath: links.appendingPathComponent("new.jsonl").path), "Symlink directory not followed")

        let backupDirectory = root.appendingPathComponent("linked-backup")
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
        let backupDestination = backupDirectory.appendingPathComponent("slides.jsonl")
        try FileManager.default.createSymbolicLink(atPath: backupDestination.path + ".previous", withDestinationPath: sentinel.path)
        let backupLog = SlideDiagnostics(destination: backupDestination, maximumBytes: 1024)
        for _ in 0..<30 { backupLog.record(.commandSent, slide: 1, total: 15) }
        backupLog.flush()
        try expect(try String(contentsOf: sentinel, encoding: .utf8) == "private sentinel", "Symlink backup target untouched")
        try expect(try Data(contentsOf: backupDestination).count <= 1024, "Invalid backup cannot grow current log past bound")
        print("Slide diagnostics: \(checks) checks passed")
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }
}
