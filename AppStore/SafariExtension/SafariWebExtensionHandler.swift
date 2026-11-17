import Foundation
import SafariServices

/// Safari's side of LocalPrompt Slides. Safari wakes this handler for each
/// message from the extension; it passes the one frame to LocalPrompt's relay
/// and answers whether LocalPrompt accepted it. Built with the SlidesBridgeKit
/// sources by scripts/build-appstore.sh.
@objc(LPSafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let payload = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var accepted = false
        if let frame = payload?["frame"] as? [String: Any],
           JSONSerialization.isValidJSONObject(frame),
           let data = try? JSONSerialization.data(withJSONObject: frame),
           let message = try? BridgeFraming.decode(data) {
            do {
                accepted = try UnixBridge.sendOnce(message)
                Self.record(accepted ? "relayAccepted" : "relayRefused", message.type.rawValue)
            } catch {
                Self.record("relayFailed", "\(message.type.rawValue): \(error.localizedDescription)")
            }
        } else {
            Self.record("invalidFrame")
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": accepted]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Troubleshooting log in this handler's own container. Fixed event names
    /// and bridge error text only; never slide titles, URLs or script text.
    private static func record(_ event: String, _ detail: String? = nil) {
        let files = FileManager.default
        guard let library = files.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let folder = library.appendingPathComponent("Logs/LocalPrompt", isDirectory: true)
        try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("safari-handler.jsonl")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 65_536 { try? files.removeItem(at: file) }
        var entry: [String: Any] = ["timestamp": Date().timeIntervalSince1970, "event": event]
        if let detail { entry["detail"] = String(detail.prefix(200)) }
        guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
        }
    }
}
