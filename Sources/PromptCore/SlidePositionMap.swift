/// Maps script words and slides using the script's silent cue boundaries.
/// The first section belongs to `startingSlide`; each later cue starts another
/// section. Pairing at a different reading position never changes that mapping.
public enum SlidePositionMap {
    /// Returns the beginning of the notes belonging to a slide. Slides skipped
    /// by consecutive cues or reached only after the closing words have no
    /// readable section, so they return nil instead of borrowing another slide's notes.
    public static func firstWord(
        forSlide position: Int,
        wordCount: Int,
        cues: [SlideCue],
        startingSlide: Int = 1,
        totalSlides: Int
    ) -> Int? {
        guard wordCount > 0, totalSlides > 0,
              startingSlide > 0, startingSlide <= totalSlides,
              position >= startingSlide, position <= totalSlides else { return nil }

        let offset = position - startingSlide
        if offset == 0 { return 0 }
        let boundaries = cues.map(\.wordPosition)
            .filter { $0 > 0 && $0 < wordCount }.sorted()
        guard offset <= boundaries.count else { return nil }
        let word = boundaries[offset - 1]
        // Several cues at one word skip empty slide sections. Only the last
        // of those sections owns this word, matching the forward mapping.
        guard offset == boundaries.count || boundaries[offset] != word else { return nil }
        return word
    }

    public static func slide(
        forWordAt index: Int,
        wordCount: Int,
        cues: [SlideCue],
        startingSlide: Int = 1,
        totalSlides: Int
    ) -> Int? {
        guard wordCount > 0, index >= 0, index < wordCount,
              totalSlides > 0, startingSlide > 0, startingSlide <= totalSlides else { return nil }

        // Position N follows N spoken words, so word index N belongs to the
        // next section. Leading cues are skipped just as SlideCueTracker skips
        // them. A closing cue at wordCount cannot precede a clickable word.
        let crossed = cues.count { $0.wordPosition > 0 && $0.wordPosition <= index }
        // Subtract first to avoid overflow when invalid offsets are supplied.
        guard crossed <= totalSlides - startingSlide else { return nil }
        return startingSlide + crossed
    }
}
