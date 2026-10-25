import Foundation
import XCTest
@testable import PromptCore

final class ScriptTrackerTests: XCTestCase {
    func testPunctuationContractionsAndUTF16Ranges() {
        let script = "🎙 Hello, café! Don’t stop—keep reading."
        var tracker = ScriptTracker(script: script)
        XCTAssertEqual(tracker.words.map(\.text), ["Hello", "café", "Don’t", "stop", "keep", "reading"])
        for word in tracker.words {
            XCTAssertEqual((script as NSString).substring(with: word.range), word.text)
        }
        XCTAssertEqual(tracker.words[0].range.location, 3)
        let result = tracker.update(transcript: "hello cafe don't stop keep reading")
        XCTAssertEqual(result.position, 6)
        XCTAssertTrue(result.didAdvance)
        XCTAssertGreaterThan(result.confidence, 0.9)
    }

    func testRepeatedPartialDoesNotConsumeRepeatedScriptPhrase() {
        var tracker = ScriptTracker(script: "We will go. We will go. We will go together.")
        XCTAssertEqual(tracker.update(transcript: "we will go").position, 3)
        for _ in 0..<5 {
            let result = tracker.update(transcript: "we will go.")
            XCTAssertEqual(result.position, 3)
            XCTAssertFalse(result.didAdvance)
        }
        XCTAssertEqual(tracker.update(transcript: "we will go we will").position, 5)
        XCTAssertEqual(tracker.update(transcript: "we will go we will go").position, 6)
        XCTAssertEqual(tracker.update(transcript: "we will go we will go we will go together").position, 10)
    }

    func testRevisionOfConsumedWordsDoesNotAdvanceAgain() {
        var tracker = ScriptTracker(script: "We know the way. We know the way home.")
        XCTAssertEqual(tracker.update(transcript: "we know the way").position, 4)
        XCTAssertEqual(tracker.update(transcript: "we know this way").position, 4)
        XCTAssertEqual(tracker.update(transcript: "we know the way").position, 4)
        XCTAssertEqual(tracker.update(transcript: "we know the").position, 4)
        XCTAssertEqual(tracker.update(transcript: "we know the way").position, 4)
        XCTAssertEqual(tracker.update(transcript: "we know the way we know the way home").position, 9)
    }

    func testUnmatchedPartialCanBeCorrectedWithoutAddingWords() {
        var tracker = ScriptTracker(script: "Welcome home everyone")
        XCTAssertEqual(tracker.update(transcript: "weather cold elsewhere").position, 0)
        XCTAssertEqual(tracker.update(transcript: "welcome home everyone").position, 3)
    }

    func testInsertedSpeechAndOmittedScriptWord() {
        var tracker = ScriptTracker(script: "Today we gather to share a wonderful story together")
        XCTAssertEqual(tracker.update(transcript: "today we gather").position, 3)
        let result = tracker.update(transcript: "today we gather um to share a story together")
        XCTAssertEqual(result.position, 9)
        XCTAssertTrue(result.didAdvance)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.72)
    }

    func testOffScriptSpeechHoldsPositionAndCanRecover() {
        var tracker = ScriptTracker(script: "Welcome home everyone. Today we gather to celebrate our community.")
        XCTAssertEqual(tracker.update(transcript: "welcome home everyone").position, 3)
        let held = tracker.update(transcript: "welcome home everyone please check microphones before starting")
        XCTAssertEqual(held.position, 3)
        XCTAssertFalse(held.didAdvance)
        XCTAssertEqual(held.confidence, 0)
        let recovered = tracker.update(transcript: "welcome home everyone please check microphones before starting today we gather to celebrate our community")
        XCTAssertEqual(recovered.position, 10)
    }

    func testLongFirstTranscriptIsProcessedInBoundedBatches() {
        let words = (0..<180).map { "word\($0)" }
        var tracker = ScriptTracker(script: words.joined(separator: " "))
        let result = tracker.update(transcript: words.joined(separator: " "))
        XCTAssertEqual(result.position, words.count)
        XCTAssertTrue(result.didAdvance)
    }

    func testSmallSkipRequiresEvidenceAndFarSkipHolds() {
        var tracker = ScriptTracker(script: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty")
        XCTAssertEqual(tracker.update(transcript: "five").position, 0)
        XCTAssertEqual(tracker.update(transcript: "five six seven").position, 7)
        XCTAssertEqual(tracker.update(transcript: "five six seven eighteen nineteen twenty").position, 7)
    }

    func testSeekPreservesSessionWatermarkAndResetPreservesPosition() {
        var tracker = ScriptTracker(script: "First part ends. Second part begins. Final part ends.")
        XCTAssertEqual(tracker.update(transcript: "first part ends").position, 3)
        tracker.seek(to: 6)
        XCTAssertEqual(tracker.update(transcript: "first part ends").position, 6)
        XCTAssertEqual(tracker.update(transcript: "first part ends final part ends").position, 9)
        tracker.seek(to: 3)
        tracker.resetTranscript()
        XCTAssertEqual(tracker.position, 3)
        XCTAssertEqual(tracker.update(transcript: "second part begins").position, 6)
        tracker.seek(to: -100)
        XCTAssertEqual(tracker.position, 0)
        tracker.seek(to: 100)
        XCTAssertEqual(tracker.position, 9)
    }

    func testEmptyScriptAndTranscript() {
        var tracker = ScriptTracker(script: "… — 🎙")
        XCTAssertTrue(tracker.words.isEmpty)
        XCTAssertEqual(tracker.update(transcript: "anything").position, 0)
        tracker = ScriptTracker(script: "Hello world")
        XCTAssertFalse(tracker.update(transcript: "").didAdvance)
        XCTAssertEqual(tracker.update(transcript: "HELLO").position, 1)
        XCTAssertEqual(tracker.update(transcript: "hello WORLD!").position, 2)
    }

    func testSmallSpellingDifferenceMatchesLongWord() {
        var tracker = ScriptTracker(script: "Welcome neighbors everybody")
        XCTAssertEqual(tracker.update(transcript: "welcome neighbours everybody").position, 3)
    }
}
