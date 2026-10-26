import Foundation
import XCTest
@testable import PromptCore

final class SlideCueTests: XCTestCase {
    func testCommandsAreSilentAndPreserveRenderedStylesAndWordRanges() {
        let source = "# Welcome everyone\n\nFirst **important** point.\n\n[[next-slide]]\n\n> Next *careful* thought.\n\n[[next-slide]]"
        let document = MarkdownDocument(source: source)
        XCTAssertEqual(document.slideCues, [SlideCue(id: 0, wordPosition: 5), SlideCue(id: 1, wordPosition: 8)])
        XCTAssertFalse(document.text.contains("next-slide"))
        XCTAssertFalse(document.trackingText.contains("LocalPromptCue"))
        XCTAssertEqual(style(of: "Welcome", in: document)?.headingLevel, 1)
        XCTAssertEqual(style(of: "important", in: document)?.bold, true)
        XCTAssertEqual(style(of: "careful", in: document)?.italic, true)
        XCTAssertEqual(style(of: "Next", in: document)?.quoteDepth, 1)
        assertAligned(document)
    }

    func testGeneratedListLabelsAndLinkDestinationsDoNotCountTowardCuePosition() {
        let document = MarkdownDocument(source: "3. Read [one **passage**](https://example.com/hidden/words).\n4. Second point.\n\n[[next-slide]]\n\nFinal words.")
        XCTAssertEqual(document.slideCues.map(\.wordPosition), [5])
        XCTAssertEqual(ScriptTracker(script: document.trackingText).words.map(\.text), ["Read", "one", "passage", "Second", "point", "Final", "words"])
        assertAligned(document)
    }

    func testCommandsHandleCRLFWhitespaceUnicodeAndHardBreaks() {
        let document = MarkdownDocument(source: "Café 👨‍👩‍👧‍👦 speaks.  \r\n  [[next-slide]] \t\r\nNext thought.")
        XCTAssertEqual(document.slideCues.map(\.wordPosition), [2])
        XCTAssertFalse(document.text.contains("next-slide"))
        XCTAssertEqual(ScriptTracker(script: document.trackingText).words.map(\.text), ["Café", "speaks", "Next", "thought"])
        assertAligned(document)
    }

    func testLeadingTrailingConsecutiveAndCueOnlyDocuments() {
        let document = MarkdownDocument(source: "[[next-slide]]\n\nFirst words.\n[[next-slide]]\n[[next-slide]]\n\nFinal words.\n[[next-slide]]")
        XCTAssertTrue(document.text.hasPrefix("First words."))
        XCTAssertEqual(document.slideCues.map(\.wordPosition), [0, 2, 2, 4])
        XCTAssertEqual(document.slideCues.map(\.id), [0, 1, 2, 3])
        assertAligned(document)
        let empty = MarkdownDocument(source: "[[next-slide]]\n[[next-slide]]\n")
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.trackingText, "")
        XCTAssertEqual(empty.runs, [])
        XCTAssertEqual(empty.slideCues.map(\.wordPosition), [0, 0])
    }

    func testInlineEscapedFencedAndIndentedExamplesDoNotTrigger() {
        for source in [
            "Say [[next-slide]] aloud.",
            "`[[next-slide]]`",
            "\\[[next-slide]]",
            "```text\n[[next-slide]]\n```",
            "~~~~\n[[next-slide]]\n~~~~",
            "    [[next-slide]]",
            "`Example begins\n[[next-slide]]\nexample ends`",
            "[[next-slide]](https://example.com)",
            "<!--\n[[next-slide]]\n-->",
        ] {
            XCTAssertTrue(MarkdownDocument(source: source).slideCues.isEmpty, source)
        }
        let mixed = MarkdownDocument(source: "```\n[[next-slide]]\n```\n\nActual notes.\n[[next-slide]]")
        XCTAssertEqual(mixed.slideCues.count, 1)
        XCTAssertTrue(mixed.text.contains("[[next-slide]]"))
        assertAligned(mixed)
    }

    func testLiteralMarkerCollisionCannotBecomeACommand() {
        let literal = "\u{E000}LocalPromptCue0\u{E001}"
        let document = MarkdownDocument(source: "\(literal) remains literal.\n[[next-slide]]\nNext notes.")
        XCTAssertTrue(document.text.contains(literal))
        XCTAssertEqual(document.slideCues.count, 1)
        assertAligned(document)
    }

    func testNaturalProgressFiresAtBoundaryOnceIncludingFinalCue() {
        let document = MarkdownDocument(source: "First two words.\n[[next-slide]]\nLast two words.\n[[next-slide]]")
        var cues = SlideCueTracker(cues: document.slideCues)
        var speech = ScriptTracker(script: document.trackingText)
        for transcript in ["First", "First two"] {
            XCTAssertTrue(cues.advance(to: speech.update(transcript: transcript).position).isEmpty)
        }
        XCTAssertEqual(cues.advance(to: speech.update(transcript: "First two words").position).map(\.id), [0])
        for transcript in ["First two words", "First two words.", "First two words Last"] {
            XCTAssertTrue(cues.advance(to: speech.update(transcript: transcript).position).isEmpty)
        }
        XCTAssertEqual(cues.advance(to: speech.update(transcript: "First two words Last two words").position).map(\.id), [1])
        XCTAssertTrue(cues.advance(to: document.trackingText.count).isEmpty)
    }

    func testRecoveryCrossesMultipleCuesInOrderAndNeverReplaysBackwardUpdates() {
        var tracker = SlideCueTracker(cues: [SlideCue(id: 0, wordPosition: 4), SlideCue(id: 1, wordPosition: 8), SlideCue(id: 2, wordPosition: 8), SlideCue(id: 3, wordPosition: 20)])
        XCTAssertEqual(tracker.advance(to: 12).map(\.id), [0, 1, 2])
        XCTAssertTrue(tracker.advance(to: 8).isEmpty)
        XCTAssertTrue(tracker.advance(to: 12).isEmpty)
        XCTAssertEqual(tracker.advance(to: 20).map(\.id), [3])
    }

    func testManualSeekNeverRearmsConsumedCuesButExplicitRewindDoes() {
        let cues = [SlideCue(id: 0, wordPosition: 0), SlideCue(id: 1, wordPosition: 3), SlideCue(id: 2, wordPosition: 6)]
        var tracker = SlideCueTracker(cues: cues)
        XCTAssertTrue(tracker.advance(to: 1).isEmpty, "Leading command has no preceding words")
        tracker.seek(to: 3)
        XCTAssertTrue(tracker.advance(to: 3).isEmpty)
        XCTAssertEqual(tracker.advance(to: 6).map(\.id), [2])
        tracker.seek(to: 2)
        XCTAssertTrue(tracker.advance(to: 3).isEmpty, "Cue skipped by seek stays consumed")
        XCTAssertTrue(tracker.advance(to: 6).isEmpty, "Previously fired cue stays consumed")
        tracker.seek(to: 100)
        XCTAssertTrue(tracker.advance(to: 101).isEmpty)
        tracker.rewind()
        XCTAssertEqual(tracker.advance(to: 6).map(\.id), [1, 2])
    }

    private func style(of value: String, in document: MarkdownDocument) -> MarkdownRun? {
        let range = (document.text as NSString).range(of: value)
        return document.runs.first { NSLocationInRange(range.location, $0.range) }
    }

    private func assertAligned(_ document: MarkdownDocument, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(document.text.utf16.count, document.trackingText.utf16.count, file: file, line: line)
        var end = 0
        for run in document.runs {
            XCTAssertEqual(run.range.location, end, file: file, line: line)
            end = NSMaxRange(run.range)
        }
        XCTAssertEqual(end, document.text.utf16.count, file: file, line: line)
        for word in ScriptTracker(script: document.trackingText).words {
            XCTAssertEqual((document.text as NSString).substring(with: word.range), word.text, file: file, line: line)
        }
    }
}
