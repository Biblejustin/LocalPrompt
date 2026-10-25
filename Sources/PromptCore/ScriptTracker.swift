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
    private var recoveryTranscriptCount = 0
    private var recoveryReference: [String] = []
    private var previousConfidence: Double = 0

    private static let contextLength = 18
    private static let batchSize = 8
    private static let maximumForwardSearch = 32
    private static let maximumSkippedWords = 8
    private static let recoverySearchLength = 320
    private static let recoveryMinimumMatches = 6
    // Function words alone are weak evidence for a distant jump, even when a
    // recognizer repeats a familiar phrase verbatim during an aside.
    private static let commonWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can",
        "could", "did", "do", "does", "for", "from", "had", "has", "have", "he",
        "her", "here", "him", "his", "how", "i", "if", "in", "is", "it", "its",
        "me", "my", "not", "of", "on", "or", "our", "she", "so", "some", "that",
        "the", "their", "them", "then", "there", "these", "they", "this", "those",
        "to", "us", "was", "we", "were", "what", "when", "which", "who", "will",
        "with", "would", "you", "your"
    ]

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
        adjustRecoveryWatermark(for: tokens)
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
            let nearby = bestMatch(in: tokens, endingAt: end)
            // A few incidental nearby words must not conceal a strong match to
            // a later sentence. Normal, well-supported reading stays on the
            // inexpensive local path.
            let recovery = (nearby?.newMatches ?? 0) < Self.recoveryMinimumMatches
                ? recoveryMatch(in: tokens, endingAt: end) : nil
            if let match = recovery ?? nearby {
                position = match.position
                consumedTranscriptCount = match.transcriptEnd
                recoveryTranscriptCount = max(recoveryTranscriptCount, match.transcriptEnd)
                if tokens.count >= recoveryTranscriptCount { recoveryReference = tokens }
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
        recoveryTranscriptCount = consumedTranscriptCount
        recoveryReference = previousTranscript
        previousConfidence = 0
    }

    /// Call before the first hypothesis from a new recognition session.
    public mutating func resetTranscript() {
        previousTranscript = []
        consumedTranscriptCount = 0
        recoveryTranscriptCount = 0
        recoveryReference = []
        previousConfidence = 0
    }

    private mutating func adjustRecoveryWatermark(for tokens: [String]) {
        // Distant recovery uses an extra conservative boundary. Keep ordinary
        // nearby tracking unchanged: revised words and genuinely new speech can
        // arrive together, and an uncertain revision must not stall that path.
        // Revisions can insert words before the watermark. Align the consumed
        // tail with the new hypothesis so old speech does not become fresh just
        // because its index grew. Prefer the earliest equally good boundary:
        // an appended repeated phrase must remain new speech, not a revision.
        // Truncations retain the high-water mark until the transcript catches up.
        guard recoveryTranscriptCount > 0,
              recoveryTranscriptCount <= recoveryReference.count else { return }
        var prefix = 0
        while prefix < min(recoveryReference.count, tokens.count),
              recoveryReference[prefix] == tokens[prefix] { prefix += 1 }
        guard prefix < recoveryTranscriptCount else { return }
        let start = max(prefix, recoveryTranscriptCount - Self.contextLength)
        let oldCount = recoveryTranscriptCount - start
        let newCount = min(tokens.count, recoveryTranscriptCount + Self.contextLength) - start
        guard newCount > 0 else { return }
        var previousRow = (0...newCount).map { -Double($0) * 1.35 }
        for oldOffset in 1...oldCount {
            var row = [Double](repeating: 0, count: newCount + 1)
            row[0] = -Double(oldOffset) * 1.5
            for newOffset in 1...newCount {
                let same = recoveryReference[start + oldOffset - 1] == tokens[start + newOffset - 1]
                row[newOffset] = max(previousRow[newOffset - 1] + (same ? 3 : -2.4),
                    previousRow[newOffset] - 1.5, row[newOffset - 1] - 1.35)
            }
            previousRow = row
        }
        var bestEnd = 0
        for end in 1...newCount where previousRow[end] > previousRow[bestEnd] + 0.001 {
            bestEnd = end
        }
        recoveryTranscriptCount = max(recoveryTranscriptCount, start + bestEnd)
        if tokens.count >= recoveryTranscriptCount { recoveryReference = tokens }
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
        let newMatches: Int
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
        var contentMask: UInt32 = 0
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
                    best = Match(position: target, transcriptEnd: cell.lastSpeech + 1, confidence: confidence, score: score, newMatches: cell.newMatches)
                }
            }
            previousRow = row
        }
        return best
    }

    private func recoveryMatch(in tokens: [String], endingAt end: Int) -> Match? {
        // Recovery never borrows already consumed speech. Otherwise a repeated
        // line elsewhere in the script could replay an earlier utterance.
        let speechStart = max(recoveryTranscriptCount, end - Self.contextLength)
        let speechCount = end - speechStart
        guard speechCount >= Self.recoveryMinimumMatches else { return nil }
        let scriptEnd = min(words.count, position + Self.recoverySearchLength)
        let scriptCount = scriptEnd - position
        guard scriptCount >= Self.recoveryMinimumMatches else { return nil }

        var previousRow = [Cell](repeating: Cell(), count: scriptCount + 1)
        var candidates: [(match: Match, start: Int)] = []
        var contentBits: [String: UInt32] = [:]
        for token in tokens[speechStart..<end] where token.count >= 3 && !Self.commonWords.contains(token) {
            if contentBits[token] == nil { contentBits[token] = 1 << contentBits.count }
        }
        for speechOffset in 1...speechCount {
            var row = [Cell](repeating: Cell(), count: scriptCount + 1)
            let speechIndex = speechStart + speechOffset - 1
            for scriptOffset in 1...scriptCount {
                let scriptIndex = position + scriptOffset - 1
                let similarity = Self.similarity(tokens[speechIndex], normalizedScript[scriptIndex])
                var diagonal = previousRow[scriptOffset - 1]
                if similarity > 0 {
                    diagonal.score += similarity == 1 ? 3 : 2.2
                    if similarity == 1 { diagonal.exact += 1 } else { diagonal.approximate += 1 }
                    if diagonal.firstScript < 0 { diagonal.firstScript = scriptIndex }
                    diagonal.lastScript = scriptIndex
                    diagonal.lastSpeech = speechIndex
                    diagonal.newMatches += 1
                    if similarity == 1 { diagonal.contentMask |= contentBits[tokens[speechIndex]] ?? 0 }
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
                      cell.lastSpeech >= end - 2,
                      cell.newMatches >= Self.recoveryMinimumMatches,
                      cell.exact >= 5 else { continue }
                let weightedMatches = Double(cell.exact) + 0.8 * Double(cell.approximate)
                let total = Double(cell.exact + cell.approximate + cell.inserted + cell.replaced + cell.deleted)
                let confidence = total > 0 ? weightedMatches / total : 0
                guard confidence >= 0.8, cell.contentMask.nonzeroBitCount >= 3 else { continue }
                candidates.append((Match(position: scriptIndex + 1,
                    transcriptEnd: cell.lastSpeech + 1, confidence: confidence,
                    score: cell.score, newMatches: cell.newMatches), cell.firstScript))
            }
            previousRow = row
        }
        candidates.sort { $0.match.score > $1.match.score }
        guard let best = candidates.first else { return nil }
        // Include nearby occurrences in ambiguity checking. An aside that quotes
        // a refrain must not jump to an arbitrary later copy of that refrain.
        if candidates.dropFirst().contains(where: {
            $0.start != best.start && $0.match.position != best.match.position &&
            best.match.score - $0.match.score < 3
        }) { return nil }
        // Leave small skips to the precise local matcher. A distant recovery
        // needs its own stronger evidence and no distance-based tie breaking.
        guard best.match.position - position - best.match.newMatches > Self.maximumSkippedWords else { return nil }
        return best.match
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
