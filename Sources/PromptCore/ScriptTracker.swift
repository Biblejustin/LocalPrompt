import Foundation

/// A display word, with its exact location in the original script.
public struct ScriptWord: Equatable, Sendable {
    public let text: String
    /// UTF-16 coordinates, suitable for NSAttributedString and NSTextView.
    public let range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }
}

public struct TrackingUpdate: Equatable, Sendable {
    /// Index of the next unread word; `words.count` means the script is complete.
    public let position: Int
    public let didAdvance: Bool
    /// Match quality in 0...1. An unmatched new hypothesis returns zero.
    public let confidence: Double
}

/// Aligns a recognizer's accumulated session transcript with a written script.
///
/// Feed each complete partial hypothesis, rather than just its newly added words.
/// A transcript watermark prevents repeated and revised hypotheses from consuming
/// the same speech twice. Position never moves backward except through `seek`.
public struct ScriptTracker: Sendable {
    public let words: [ScriptWord]
    public private(set) var position: Int = 0

    private let normalizedScript: [String]
    private var previousTranscript: [String] = []
    private var consumedTranscriptCount = 0
    private var previousConfidence: Double = 0

    private static let contextLength = 18
    private static let batchSize = 8
    private static let maximumForwardSearch = 32
    private static let maximumSkippedWords = 8

    public init(script: String) {
        words = Self.tokenize(script)
        normalizedScript = words.map { Self.normalize($0.text) }
    }

    public mutating func update(transcript: String) -> TrackingUpdate {
        let tokens = Self.tokenize(transcript).map { Self.normalize($0.text) }
        guard tokens != previousTranscript else {
            return TrackingUpdate(position: position, didAdvance: false, confidence: previousConfidence)
        }

        let initialPosition = position
        let previousCount = previousTranscript.count
        previousTranscript = tokens
        guard position < words.count, tokens.count > consumedTranscriptCount else {
            previousConfidence = 0
            return TrackingUpdate(position: position, didAdvance: false, confidence: 0)
        }

        // Recognition can deliver a whole sentence or recording at once. Small
        // batches keep the search bounded without losing a long first result.
        var end = min(tokens.count, max(consumedTranscriptCount, previousCount) + Self.batchSize)
        var confidence: Double = 0
        while true {
            if let match = bestMatch(in: tokens, endingAt: end) {
                position = match.position
                consumedTranscriptCount = match.transcriptEnd
                confidence = match.confidence
            }
            if end == tokens.count || position == words.count { break }
            end = min(tokens.count, end + Self.batchSize)
        }

        previousConfidence = confidence
        return TrackingUpdate(position: position, didAdvance: position > initialPosition, confidence: confidence)
    }

    /// Moves explicitly, and ignores speech already present in this session.
    /// A recognizer can continue sending accumulated hypotheses after a seek.
    public mutating func seek(to index: Int) {
        position = min(max(0, index), words.count)
        consumedTranscriptCount = previousTranscript.count
        previousConfidence = 0
    }

    /// Call before the first hypothesis from a new recognition session.
    public mutating func resetTranscript() {
        previousTranscript = []
        consumedTranscriptCount = 0
        previousConfidence = 0
    }

    private static func tokenize(_ text: String) -> [ScriptWord] {
        // Keep contractions together; hyphens and all other punctuation separate
        // words. NSRegularExpression supplies the renderer's UTF-16 ranges.
        let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            ScriptWord(text: source.substring(with: $0.range), range: $0.range)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    private struct Match {
        let position: Int
        let transcriptEnd: Int
        let confidence: Double
        let score: Double
    }

    private struct Cell {
        var score: Double = 0
        var exact = 0
        var approximate = 0
        var inserted = 0
        var deleted = 0
        var replaced = 0
        var newMatches = 0
        var firstScript = -1
        var lastScript = -1
        var lastSpeech = -1
    }

    private func bestMatch(in tokens: [String], endingAt end: Int) -> Match? {
        // A shorter suffix lets a reader resume after an aside. The longest
        // confident alignment still wins, preserving context at repeated phrases.
        var best: Match?
        for contextLength in [Self.contextLength, 12, 8, 4] {
            guard let candidate = match(in: tokens, endingAt: end, contextLength: contextLength) else { continue }
            if best == nil || candidate.score > best!.score + 0.001 ||
                (abs(candidate.score - best!.score) < 0.001 && candidate.position < best!.position) {
                best = candidate
            }
        }
        return best
    }

    private func match(in tokens: [String], endingAt end: Int, contextLength: Int) -> Match? {
        guard end > consumedTranscriptCount else { return nil }
        let speechStart = max(0, end - contextLength)
        let scriptStart = max(0, position - Self.contextLength)
        let unseenCount = end - consumedTranscriptCount
        let scriptEnd = min(words.count, position + min(Self.maximumForwardSearch, unseenCount + Self.maximumSkippedWords))
        let speechCount = end - speechStart
        let scriptCount = scriptEnd - scriptStart
        guard scriptCount > 0 else { return nil }

        var previousRow = [Cell](repeating: Cell(), count: scriptCount + 1)
        var best: Match?
        for speechOffset in 1...speechCount {
            var row = [Cell](repeating: Cell(), count: scriptCount + 1)
            let speechIndex = speechStart + speechOffset - 1
            for scriptOffset in 1...scriptCount {
                let scriptIndex = scriptStart + scriptOffset - 1
                let similarity = Self.similarity(tokens[speechIndex], normalizedScript[scriptIndex])
                var diagonal = previousRow[scriptOffset - 1]
                if similarity > 0 {
                    diagonal.score += similarity == 1 ? 3 : 2.2
                    if similarity == 1 { diagonal.exact += 1 } else { diagonal.approximate += 1 }
                    if diagonal.firstScript < 0 { diagonal.firstScript = scriptIndex }
                    diagonal.lastScript = scriptIndex
                    diagonal.lastSpeech = speechIndex
                    if speechIndex >= consumedTranscriptCount && scriptIndex >= position {
                        diagonal.newMatches += 1
                    }
                } else {
                    diagonal.score -= 2.4
                    diagonal.replaced += 1
                }
                var insertion = previousRow[scriptOffset]
                insertion.score -= 1.35
                insertion.inserted += 1
                var deletion = row[scriptOffset - 1]
                deletion.score -= 1.5
                deletion.deleted += 1

                var cell = diagonal
                if insertion.score > cell.score { cell = insertion }
                if deletion.score > cell.score { cell = deletion }
                if cell.score <= 0 { cell = Cell() }
                row[scriptOffset] = cell

                guard speechOffset == speechCount,
                      cell.lastScript == scriptIndex,
                      cell.lastScript >= position,
                      cell.lastSpeech >= consumedTranscriptCount,
                      cell.lastSpeech >= end - 3,
                      cell.newMatches > 0 else { continue }

                let target = cell.lastScript + 1
                let advance = target - position
                let omitted = advance - cell.newMatches
                guard omitted <= Self.maximumSkippedWords else { continue }
                if omitted == 1 && cell.newMatches < 2 { continue }
                if omitted > 1 && cell.newMatches < 3 { continue }

                let weightedMatches = Double(cell.exact) + 0.8 * Double(cell.approximate)
                let total = Double(cell.exact + cell.approximate + cell.inserted + cell.replaced) + 0.65 * Double(cell.deleted)
                let confidence = total > 0 ? min(1, weightedMatches / total) : 0
                guard confidence >= 0.72 else { continue }

                // Equal repeated phrases choose the nearest forward occurrence.
                let score = cell.score - Double(max(0, cell.firstScript - position)) * 0.3 - Double(max(0, omitted)) * 0.1
                if best == nil || score > best!.score + 0.001 || (abs(score - best!.score) < 0.001 && target < best!.position) {
                    best = Match(position: target, transcriptEnd: cell.lastSpeech + 1, confidence: confidence, score: score)
                }
            }
            previousRow = row
        }
        return best
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        // One character's difference catches small recognition/spelling variants;
        // short words must match exactly to avoid accidental jumps.
        let left = Array(lhs)
        let right = Array(rhs)
        guard min(left.count, right.count) >= 5, abs(left.count - right.count) <= 1 else { return 0 }
        var i = 0
        var j = 0
        var edits = 0
        while i < left.count && j < right.count {
            if left[i] == right[j] {
                i += 1
                j += 1
            } else {
                edits += 1
                if edits > 1 { return 0 }
                if left.count >= right.count { i += 1 }
                if right.count >= left.count { j += 1 }
            }
        }
        edits += left.count - i + right.count - j
        return edits <= 1 ? 0.8 : 0
    }
}
