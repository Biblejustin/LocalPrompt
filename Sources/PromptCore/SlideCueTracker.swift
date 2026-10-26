import Foundation

/// A silent next-slide command after `wordPosition` spoken words.
public struct SlideCue: Equatable, Identifiable, Sendable {
    public let id: Int
    public let wordPosition: Int

    public init(id: Int, wordPosition: Int) {
        self.id = id
        self.wordPosition = max(0, wordPosition)
    }
}

/// Emits cues once when natural reading crosses their word boundaries.
/// Manual navigation must call `seek`; it never emits presentation commands.
public struct SlideCueTracker: Sendable {
    public let cues: [SlideCue]
    public private(set) var position: Int
    private var nextCueIndex: Int
    private var consumed: Set<Int>

    public init(cues: [SlideCue], position: Int = 0) {
        self.cues = cues.enumerated().sorted {
            $0.element.wordPosition == $1.element.wordPosition
                ? $0.offset < $1.offset : $0.element.wordPosition < $1.element.wordPosition
        }.map(\.element)
        let startingPosition = max(0, position)
        self.position = startingPosition
        nextCueIndex = self.cues.firstIndex { $0.wordPosition > startingPosition } ?? self.cues.count
        consumed = Set(0..<nextCueIndex)
    }

    /// Call only for active voice/timed progression. Repeated positions and
    /// backwards recognizer updates cannot replay an already crossed cue.
    public mutating func advance(to newPosition: Int) -> [SlideCue] {
        guard newPosition > position else { return [] }
        position = newPosition
        var result: [SlideCue] = []
        while nextCueIndex < cues.count, cues[nextCueIndex].wordPosition <= position {
            if consumed.insert(nextCueIndex).inserted { result.append(cues[nextCueIndex]) }
            nextCueIndex += 1
        }
        return result
    }

    /// Seeking skips cues at or before the destination without firing. Backward
    /// seek preserves consumed cues: an accidental click cannot advance twice.
    /// A cue at zero is intentionally skipped: it has no preceding spoken notes.
    public mutating func seek(to newPosition: Int) {
        position = max(0, newPosition)
        nextCueIndex = cues.firstIndex { $0.wordPosition > position } ?? cues.count
        consumed.formUnion(0..<nextCueIndex)
    }

    /// Explicitly starts a new reading pass, rearming cues after the first word.
    /// The caller remains responsible for resetting the actual presentation.
    public mutating func rewind() { self = Self(cues: cues) }
}
