import XCTest
@testable import PromptCore

final class SlidePositionMapTests: XCTestCase {
    func testFirstWordFindsStartOfEachSlidesNotes() {
        let document = MarkdownDocument(source: "First words.\n[[next-slide]]\nSecond words.\n[[next-slide]]\nFinal words.\n[[next-slide]]")
        let wordCount = ScriptTracker(script: document.trackingText).words.count
        XCTAssertEqual((1...4).map {
            SlidePositionMap.firstWord(forSlide: $0, wordCount: wordCount, cues: document.slideCues, totalSlides: 4)
        }, [0, 2, 4, nil])
    }

    func testFirstWordUsesStartingSlideAndRejectsUncoveredSlides() {
        let cues = [SlideCue(id: 0, wordPosition: 2), SlideCue(id: 1, wordPosition: 4)]
        XCTAssertEqual((1...8).map {
            SlidePositionMap.firstWord(forSlide: $0, wordCount: 6, cues: cues, startingSlide: 4, totalSlides: 8)
        }, [nil, nil, nil, 0, 2, 4, nil, nil])
    }

    func testFirstWordRejectsEmptySectionsAtDuplicateUnsortedBoundaries() {
        let cues = [SlideCue(id: 0, wordPosition: 4), SlideCue(id: 1, wordPosition: 2), SlideCue(id: 2, wordPosition: 2)]
        XCTAssertEqual((1...4).map {
            SlidePositionMap.firstWord(forSlide: $0, wordCount: 6, cues: cues, totalSlides: 4)
        }, [0, nil, 2, 4])
    }

    func testFirstWordIgnoresLeadingAndOutOfScriptCues() {
        let cues = [SlideCue(id: 0, wordPosition: 0), SlideCue(id: 1, wordPosition: 0),
                    SlideCue(id: 2, wordPosition: 1), SlideCue(id: 3, wordPosition: Int.max)]
        XCTAssertEqual(SlidePositionMap.firstWord(forSlide: 1, wordCount: 1, cues: cues, totalSlides: 4), 0)
        XCTAssertNil(SlidePositionMap.firstWord(forSlide: 2, wordCount: 1, cues: cues, totalSlides: 4))
        XCTAssertEqual(SlidePositionMap.firstWord(forSlide: 7, wordCount: 100, cues: [], startingSlide: 7, totalSlides: 8), 0)
        XCTAssertNil(SlidePositionMap.firstWord(forSlide: 8, wordCount: 100, cues: [], startingSlide: 7, totalSlides: 8))
    }

    func testFirstWordRejectsInvalidInputsWithoutOverflow() {
        let cues = [SlideCue(id: 0, wordPosition: 2)]
        for slide in [Int.min, -1, 0, 3, Int.max] {
            XCTAssertNil(SlidePositionMap.firstWord(forSlide: slide, wordCount: 3, cues: cues, totalSlides: 2))
        }
        for count in [-1, 0] {
            XCTAssertNil(SlidePositionMap.firstWord(forSlide: 1, wordCount: count, cues: [], totalSlides: 2))
        }
        for total in [-1, 0] {
            XCTAssertNil(SlidePositionMap.firstWord(forSlide: 1, wordCount: 3, cues: cues, totalSlides: total))
        }
        for start in [Int.min, -1, 0, 3] {
            XCTAssertNil(SlidePositionMap.firstWord(forSlide: 1, wordCount: 3, cues: cues, startingSlide: start, totalSlides: 2))
        }
        XCTAssertEqual(SlidePositionMap.firstWord(forSlide: Int.max, wordCount: 3, cues: cues, startingSlide: Int.max, totalSlides: Int.max), 0)
        XCTAssertNil(SlidePositionMap.firstWord(forSlide: Int.max, wordCount: 3, cues: cues, totalSlides: Int.max))
    }

    func testEveryInverseDestinationMatchesFirstForwardMappedWord() {
        for positions in [[], [0], [2, 4], [4, 2, 2], [0, 0, 2, 6], [2, 2, 2, 4, 4, 7]] {
            let cues = positions.enumerated().map { SlideCue(id: $0.offset, wordPosition: $0.element) }
            for start in [1, 4] {
                for slide in 1...10 {
                    let expected = (0..<6).first {
                        SlidePositionMap.slide(forWordAt: $0, wordCount: 6, cues: cues, startingSlide: start, totalSlides: 10) == slide
                    }
                    XCTAssertEqual(SlidePositionMap.firstWord(forSlide: slide, wordCount: 6, cues: cues, startingSlide: start, totalSlides: 10), expected)
                }
            }
        }
    }

    func testClickedWordsUseInclusiveCueBoundaries() {
        let document = MarkdownDocument(source: "First words.\n[[next-slide]]\nSecond words.\n[[next-slide]]\nFinal words.\n[[next-slide]]")
        let wordCount = ScriptTracker(script: document.trackingText).words.count
        XCTAssertEqual(wordCount, 6)
        XCTAssertEqual((0..<wordCount).map {
            SlidePositionMap.slide(forWordAt: $0, wordCount: wordCount, cues: document.slideCues, totalSlides: 3)
        }, [1, 1, 2, 2, 3, 3])
        XCTAssertNil(SlidePositionMap.slide(forWordAt: wordCount, wordCount: wordCount, cues: document.slideCues, totalSlides: 3))
    }

    func testLeadingAndClosingCuesDoNotMoveSingleWordSection() {
        let cues = [SlideCue(id: 0, wordPosition: 0), SlideCue(id: 1, wordPosition: 0), SlideCue(id: 2, wordPosition: 1)]
        XCTAssertEqual(SlidePositionMap.slide(forWordAt: 0, wordCount: 1, cues: cues, totalSlides: 1), 1)
    }

    func testConsecutiveBoundariesCountEverySlideRegardlessOfCueOrder() {
        let cues = [SlideCue(id: 0, wordPosition: 4), SlideCue(id: 1, wordPosition: 2), SlideCue(id: 2, wordPosition: 2)]
        XCTAssertEqual(SlidePositionMap.slide(forWordAt: 1, wordCount: 6, cues: cues, totalSlides: 4), 1)
        XCTAssertEqual(SlidePositionMap.slide(forWordAt: 2, wordCount: 6, cues: cues, totalSlides: 4), 3)
        XCTAssertEqual(SlidePositionMap.slide(forWordAt: 4, wordCount: 6, cues: cues, totalSlides: 4), 4)
    }

    func testPartialScriptUsesExplicitStartingSlide() {
        let cues = [SlideCue(id: 0, wordPosition: 2), SlideCue(id: 1, wordPosition: 4)]
        XCTAssertEqual(SlidePositionMap.slide(forWordAt: 0, wordCount: 6, cues: cues, startingSlide: 4, totalSlides: 8), 4)
        XCTAssertEqual(SlidePositionMap.slide(forWordAt: 2, wordCount: 6, cues: cues, startingSlide: 4, totalSlides: 8), 5)
        XCTAssertEqual(SlidePositionMap.slide(forWordAt: 5, wordCount: 6, cues: cues, startingSlide: 4, totalSlides: 8), 6)
    }

    func testInvalidInputsAndOutOfDeckDestinationAreRejected() {
        let cues = [SlideCue(id: 0, wordPosition: 2)]
        for index in [-1, 3, Int.max] {
            XCTAssertNil(SlidePositionMap.slide(forWordAt: index, wordCount: 3, cues: cues, totalSlides: 2))
        }
        for count in [-1, 0] {
            XCTAssertNil(SlidePositionMap.slide(forWordAt: 0, wordCount: count, cues: [], totalSlides: 2))
        }
        for total in [-1, 0] {
            XCTAssertNil(SlidePositionMap.slide(forWordAt: 0, wordCount: 3, cues: cues, totalSlides: total))
        }
        for start in [-1, 0, 3] {
            XCTAssertNil(SlidePositionMap.slide(forWordAt: 0, wordCount: 3, cues: cues, startingSlide: start, totalSlides: 2))
        }
        XCTAssertNil(SlidePositionMap.slide(forWordAt: 2, wordCount: 3, cues: cues, startingSlide: 2, totalSlides: 2))
        XCTAssertNil(SlidePositionMap.slide(forWordAt: 2, wordCount: 3, cues: cues, startingSlide: Int.max, totalSlides: Int.max))
    }

    func testScriptWithoutCuesStaysOnStartingSlide() {
        XCTAssertEqual(SlidePositionMap.slide(forWordAt: 99, wordCount: 100, cues: [], startingSlide: 7, totalSlides: 7), 7)
    }

    func testConfirmedBackwardJumpCanRebaseFutureCues() {
        let cues = [SlideCue(id: 0, wordPosition: 0), SlideCue(id: 1, wordPosition: 3), SlideCue(id: 2, wordPosition: 6)]
        var tracker = SlideCueTracker(cues: cues)
        XCTAssertEqual(tracker.advance(to: 8).map(\.id), [1, 2])
        XCTAssertEqual(SlidePositionMap.slide(forWordAt: 2, wordCount: 9, cues: cues, totalSlides: 3), 1)

        // After the deck confirms the backward jump, start cue tracking from
        // that word. Ordinary seek deliberately retains consumed cues instead.
        tracker = SlideCueTracker(cues: cues, position: 2)
        XCTAssertEqual(tracker.advance(to: 3).map(\.id), [1])
        XCTAssertEqual(tracker.advance(to: 6).map(\.id), [2])
        XCTAssertTrue(tracker.advance(to: 6).isEmpty)
    }
}
