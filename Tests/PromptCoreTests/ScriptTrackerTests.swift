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

    func testTwelveWordSkipRecoversAfterSixDistinctiveWordsAndKeepsFollowing() {
        let opening = "Welcome friends tonight"
        let skipped = "Earlier notes describe morning travel weather preparations schedules supplies plans duties assignments"
        let continuation = "Fresh lanterns illuminate narrow pathways beside the peaceful garden tonight"
        var tracker = ScriptTracker(script: "\(opening) \(skipped) \(continuation)")
        XCTAssertEqual(tracker.update(transcript: opening).position, 3)
        var transcript = opening
        for (offset, word) in continuation.split(separator: " ").enumerated() {
            transcript += " " + word
            let result = tracker.update(transcript: transcript)
            if offset < 5 {
                XCTAssertEqual(result.position, 3, "Recovery needs six words of evidence")
            } else {
                XCTAssertEqual(result.position, 15 + offset + 1)
            }
        }
        XCTAssertEqual(tracker.position, tracker.words.count)
    }

    func testStrongRecoveryWinsOverIncidentalNearbyWords() {
        let opening = "Welcome friends tonight"
        let skipped = "Fresh lanterns consider these earlier morning notes before everyone starts walking home"
        let continuation = "Fresh lanterns illuminate narrow pathways beside peaceful gardens"
        var tracker = ScriptTracker(script: "\(opening) \(skipped) \(continuation)")
        XCTAssertEqual(tracker.update(transcript: opening).position, 3)
        XCTAssertEqual(tracker.update(transcript: "\(opening) \(continuation)").position, tracker.words.count)
    }

    func testLargeSkipRecoversWithinBoundedSearchAndIgnoresBeyondIt() {
        let opening = "Welcome friends tonight"
        let continuation = "Fresh lanterns illuminate narrow pathways beside peaceful gardens"
        for skippedCount in [40, 200, 300, 330] {
            let skipped = Array(repeating: "omitted", count: skippedCount).joined(separator: " ")
            var tracker = ScriptTracker(script: "\(opening) \(skipped) \(continuation)")
            XCTAssertEqual(tracker.update(transcript: opening).position, 3)
            let result = tracker.update(transcript: "\(opening) \(continuation)")
            XCTAssertEqual(result.position, skippedCount <= 300 ? tracker.words.count : 3)
        }
    }

    func testLongAdLibHoldsAndResumesWithoutUsingOldSpeechForRecovery() {
        let opening = "Welcome friends tonight"
        let continuation = "Fresh lanterns illuminate narrow pathways beside peaceful gardens"
        var tracker = ScriptTracker(script: "\(opening) \(continuation)")
        XCTAssertEqual(tracker.update(transcript: opening).position, 3)
        var transcript = opening
        let aside = "Please check microphones because someone mentioned feedback near speakers yesterday before rehearsal"
        for _ in 0..<4 {
            transcript += " " + aside
            XCTAssertEqual(tracker.update(transcript: transcript).position, 3)
        }
        transcript += " " + continuation
        XCTAssertEqual(tracker.update(transcript: transcript).position, tracker.words.count)
    }

    func testRepeatedRecoveryPhraseWaitsForDisambiguatingWords() {
        let opening = "Welcome friends tonight"
        let skipped = Array(repeating: "omitted", count: 20).joined(separator: " ")
        let refrain = "Bright lanterns guide weary travelers safely"
        let ending = "toward distant harbor gates"
        var tracker = ScriptTracker(script: "\(opening) \(skipped) \(refrain) \(skipped) \(refrain) \(ending)")
        XCTAssertEqual(tracker.update(transcript: opening).position, 3)
        let ambiguous = tracker.update(transcript: "\(opening) \(refrain)")
        XCTAssertEqual(ambiguous.position, 3)
        XCTAssertEqual(ambiguous.confidence, 0)
        XCTAssertEqual(tracker.update(transcript: "\(opening) \(refrain) \(ending)").position, tracker.words.count)
    }

    func testCommonWordsAloneCannotTriggerDistantRecovery() {
        let skipped = Array(repeating: "omitted", count: 40).joined(separator: " ")
        var tracker = ScriptTracker(script: "Welcome friends tonight \(skipped) we are here and we will be there")
        XCTAssertEqual(tracker.update(transcript: "Welcome friends tonight").position, 3)
        XCTAssertEqual(tracker.update(transcript: "Welcome friends tonight we are here and we will be there").position, 3)
    }

    func testRecoveryToleratesInsertedAndMissedRecognitionWords() {
        let opening = "Welcome friends tonight"
        let skipped = Array(repeating: "omitted", count: 40).joined(separator: " ")
        let continuation = "Fresh lanterns illuminate narrow pathways beside the peaceful garden tonight"
        var tracker = ScriptTracker(script: "\(opening) \(skipped) \(continuation)")
        XCTAssertEqual(tracker.update(transcript: opening).position, 3)
        let noisy = "fresh lanterns illuminate um narrow pathways beside peaceful garden tonight"
        let result = tracker.update(transcript: "\(opening) \(noisy)")
        XCTAssertEqual(result.position, tracker.words.count)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.8)
    }

    func testRevisedAndRepeatedRecoveryHypothesesNeverConsumeSpeechTwice() {
        let opening = "Welcome friends tonight"
        let skipped = Array(repeating: "omitted", count: 20).joined(separator: " ")
        let phrase = "Fresh lanterns illuminate narrow pathways beside peaceful gardens"
        var tracker = ScriptTracker(script: "\(opening) \(skipped) \(phrase) \(skipped) Another ending")
        XCTAssertEqual(tracker.update(transcript: opening).position, 3)
        let transcript = "\(opening) \(phrase)"
        let recoveredPosition = tracker.update(transcript: transcript).position
        XCTAssertEqual(recoveredPosition, 31)
        XCTAssertFalse(tracker.update(transcript: transcript).didAdvance)
        XCTAssertEqual(tracker.update(transcript: "Welcome neighbors tonight \(phrase)").position, recoveredPosition)
        XCTAssertEqual(tracker.update(transcript: "Welcome neighbors tonight Fresh lanterns").position, recoveredPosition)
        XCTAssertEqual(tracker.update(transcript: transcript).position, recoveredPosition)
    }

    func testConsumedPrefixInsertionDoesNotReplayWordsAtDistantCopy() {
        let phrase = "Fresh lanterns illuminate narrow pathways beside peaceful gardens"
        let skipped = Array(repeating: "omitted", count: 20).joined(separator: " ")
        var tracker = ScriptTracker(script: "\(phrase) \(skipped) \(phrase)")
        XCTAssertEqual(tracker.update(transcript: phrase).position, 8)
        let revised = "Please consider these additional introductory words \(phrase)"
        XCTAssertEqual(tracker.update(transcript: "Fresh lanterns").position, 8)
        XCTAssertEqual(tracker.update(transcript: revised).position, 8)
        XCTAssertEqual(tracker.update(transcript: revised).position, 8)
        XCTAssertEqual(tracker.update(transcript: "\(revised) \(phrase)").position, tracker.words.count)
    }

    func testRevisionAndFreshRepeatedSpeechInSameHypothesisRemainTrackable() {
        var tracker = ScriptTracker(script: "We know the way. We know the way home.")
        XCTAssertEqual(tracker.update(transcript: "we know the way").position, 4)
        XCTAssertEqual(tracker.update(transcript: "we know this way we know the way").position, 8)
        XCTAssertEqual(tracker.update(transcript: "we know this way we know the way home").position, 9)
    }

    func testMultipleRevisionsAndFreshRepeatedSpeechRemainTrackable() {
        var tracker = ScriptTracker(script: "We know the way. We know the way home.")
        XCTAssertEqual(tracker.update(transcript: "we know the way").position, 4)
        XCTAssertEqual(tracker.update(transcript: "we learned this way we know the way").position, 8)
        XCTAssertEqual(tracker.update(transcript: "we learned this way we know the way home").position, 9)
    }

    func testPrefixInsertionAndFreshSpeechInSameHypothesisRemainTrackable() {
        var tracker = ScriptTracker(script: "Bright lanterns guide weary travelers safely toward distant harbor gates")
        XCTAssertEqual(tracker.update(transcript: "bright lanterns guide weary travelers safely").position, 6)
        XCTAssertEqual(tracker.update(transcript: "bright glowing lanterns guide weary travelers safely toward distant harbor gates").position, 10)
    }

    func testSeekAndTranscriptResetDiscardOldRecoveryEvidence() {
        let phrase = "Fresh lanterns illuminate narrow pathways beside peaceful gardens"
        let skipped = Array(repeating: "omitted", count: 20).joined(separator: " ")
        var tracker = ScriptTracker(script: "\(phrase) \(skipped) \(phrase)")
        XCTAssertEqual(tracker.update(transcript: phrase).position, 8)
        tracker.seek(to: 0)
        XCTAssertEqual(tracker.update(transcript: phrase + " yesterday").position, 0)
        tracker.seek(to: 8)
        tracker.resetTranscript()
        XCTAssertEqual(tracker.update(transcript: phrase).position, tracker.words.count)
    }

}
