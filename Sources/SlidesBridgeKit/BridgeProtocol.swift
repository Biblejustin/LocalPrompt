import Foundation

public enum SlidesBridgeIdentity {
    public static let hostName = "com.biblejustin.localprompt.slides"
    public static let extensionID = "ojnmagbchlkpiajkkpkchacbbmnpmlid"
    public static let extensionOrigin = "chrome-extension://\(extensionID)/"
    public static let maximumFrameBytes = 65_536
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalPrompt/SlidesBridge", isDirectory: true)
    }
    public static var socketPath: String { directory.appendingPathComponent("bridge.sock").path }
}

public struct SlideSnapshot: Codable, Equatable, Sendable {
    public var deckID: String
    public var title: String
    public var pageID: String
    public var slideID: String
    public var position: Int
    public var total: Int

    public init(deckID: String, title: String, pageID: String, slideID: String, position: Int, total: Int) {
        self.deckID = deckID; self.title = title; self.pageID = pageID
        self.slideID = slideID; self.position = position; self.total = total
    }

    public func validate() throws {
        guard !deckID.isEmpty, deckID.utf8.count <= 256,
              !pageID.isEmpty, pageID.utf8.count <= 256,
              !slideID.isEmpty, slideID.utf8.count <= 256,
              title.utf8.count <= 2_048, position > 0, total >= position, total <= 10_000 else {
            throw SlidesBridgeError.invalidMessage
        }
    }

    public func samePresentation(as other: SlideSnapshot) -> Bool {
        deckID == other.deckID && pageID == other.pageID && total == other.total
    }
}

public struct BridgeMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case hello, command, result, disconnect }
    public enum Operation: String, Codable, Sendable { case status, advance }
    public var v: Int = 1
    public var type: Kind
    public var session: String
    public var requestID: Int?
    public var operation: Operation?
    public var snapshot: SlideSnapshot?
    public var error: String?
    public var ended: Bool?

    public init(type: Kind, session: String, requestID: Int? = nil, operation: Operation? = nil,
                snapshot: SlideSnapshot? = nil, error: String? = nil, ended: Bool? = nil) {
        self.type = type; self.session = session; self.requestID = requestID; self.operation = operation
        self.snapshot = snapshot; self.error = error; self.ended = ended
    }

    public func validate() throws {
        guard v == 1, (16...128).contains(session.utf8.count),
              session.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }),
              error == nil || error!.utf8.count <= 2_048 else { throw SlidesBridgeError.invalidMessage }
        if let requestID, !(1...2_147_483_647).contains(requestID) { throw SlidesBridgeError.invalidMessage }
        try snapshot?.validate()
        switch type {
        case .hello:
            guard snapshot != nil, requestID == nil, operation == nil, error == nil, ended == nil else { throw SlidesBridgeError.invalidMessage }
        case .command:
            guard requestID != nil, operation != nil, error == nil, ended == nil,
                  operation != .advance || snapshot != nil else { throw SlidesBridgeError.invalidMessage }
        case .result:
            guard requestID != nil, operation == nil,
                  snapshot != nil || error != nil || ended == true else { throw SlidesBridgeError.invalidMessage }
        case .disconnect:
            guard requestID == nil, operation == nil else { throw SlidesBridgeError.invalidMessage }
        }
    }
}

public enum SlidesBridgeError: LocalizedError, Equatable {
    case invalidMessage, oversizedFrame, invalidFrame, disconnected, timeout, unsafePath, pathTooLong, alreadyRunning
    case system(String)
    public var errorDescription: String? {
        switch self {
        case .invalidMessage: return "Slide bridge received an invalid message. Reconnect the slideshow."
        case .oversizedFrame: return "Slide bridge message exceeded its size limit."
        case .invalidFrame: return "Slide bridge received an invalid frame."
        case .disconnected: return "Brave slide connection closed. Check the slideshow and reconnect."
        case .timeout: return "Brave did not respond in time. Check the slide before reconnecting; no retry was sent."
        case .unsafePath: return "Local slide bridge folder has unsafe ownership or permissions."
        case .pathTooLong: return "Local slide bridge folder path is too long for a Mac socket."
        case .alreadyRunning: return "Another LocalPrompt slide bridge is running. Close the other copy first."
        case .system(let text): return "Local slide bridge: \(text)"
        }
    }
}

public enum BridgeFraming {
    public static func encode(_ message: BridgeMessage) throws -> Data {
        try message.validate()
        let payload = try JSONEncoder().encode(message)
        guard !payload.isEmpty, payload.count <= SlidesBridgeIdentity.maximumFrameBytes else { throw SlidesBridgeError.oversizedFrame }
        var length = UInt32(payload.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(payload)
        return data
    }

    public static func decode(_ payload: Data) throws -> BridgeMessage {
        guard !payload.isEmpty, payload.count <= SlidesBridgeIdentity.maximumFrameBytes else { throw SlidesBridgeError.oversizedFrame }
        let value = try JSONDecoder().decode(BridgeMessage.self, from: payload)
        try value.validate()
        return value
    }
}

/// Bounded incremental parser shared by the socket and native-host pipes.
public struct BridgeFrameDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [BridgeMessage] {
        // Callers feed fixed-size read chunks, never an unbounded stream.
        guard data.count <= SlidesBridgeIdentity.maximumFrameBytes + 4,
              buffer.count + data.count <= 2 * (SlidesBridgeIdentity.maximumFrameBytes + 4) else { throw SlidesBridgeError.oversizedFrame }
        buffer.append(data)
        var messages: [BridgeMessage] = []
        while buffer.count >= 4 {
            let count = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
            guard count > 0, count <= SlidesBridgeIdentity.maximumFrameBytes else { throw SlidesBridgeError.oversizedFrame }
            guard buffer.count >= count + 4 else { break }
            messages.append(try BridgeFraming.decode(Data(buffer.dropFirst(4).prefix(count))))
            buffer.removeFirst(count + 4)
        }
        return messages
    }
    public var hasPartialFrame: Bool { !buffer.isEmpty }
}
