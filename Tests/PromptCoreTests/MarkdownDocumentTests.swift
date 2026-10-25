import Foundation
import XCTest
@testable import PromptCore

final class MarkdownDocumentTests: XCTestCase {
    func testHeadingsEmphasisAndQuote() {
        let source = "# Practice Session\n\n## Speak at Your Pace\n\nRemember to **pause**.\n\n> Give each idea room to breathe."
        let document = MarkdownDocument(source: source)
        XCTAssertEqual(document.text, "Practice Session\n\nSpeak at Your Pace\n\nRemember to pause.\n\nGive each idea room to breathe.")
        XCTAssertEqual(document.trackingText, document.text)
        XCTAssertEqual(style(of: "Practice Session", in: document)?.headingLevel, 1)
        XCTAssertEqual(style(of: "Speak at Your Pace", in: document)?.headingLevel, 2)
        XCTAssertEqual(style(of: "pause", in: document)?.bold, true)
        XCTAssertEqual(style(of: "Give each idea room to breathe.", in: document)?.quoteDepth, 1)
    }

    func testLinksKeepLabelsAndNeverTrackDestinations() {
        let document = MarkdownDocument(source: "Read [John **14**](https://example.com/secret-path) and [this passage][verse].\n\n[verse]: https://example.org/other")
        XCTAssertEqual(document.text, "Read John 14 and this passage.")
        XCTAssertEqual(document.trackingText, document.text)
        XCTAssertEqual(ScriptTracker(script: document.trackingText).words.map(\.text), ["Read", "John", "14", "and", "this", "passage"])
        XCTAssertEqual(style(of: "14", in: document)?.bold, true)
    }

    func testGeneratedListLabelsAreExcludedFromSpeechWithAlignedRanges() {
        let document = MarkdownDocument(source: "3. First 🌍 **word**\n4. Second\n   - Child\n   - Other\n5. Third")
        XCTAssertEqual(document.text, "3. First 🌍 word\n4. Second\n• Child\n• Other\n5. Third")
        XCTAssertEqual(document.text.utf16.count, document.trackingText.utf16.count)
        let tracker = ScriptTracker(script: document.trackingText)
        XCTAssertEqual(tracker.words.map(\.text), ["First", "word", "Second", "Child", "Other", "Third"])
        for word in tracker.words {
            XCTAssertEqual((document.text as NSString).substring(with: word.range), word.text)
        }
        XCTAssertEqual(style(of: "Child", in: document)?.listDepth, 2)
        XCTAssertEqual(style(of: "Third", in: document)?.listDepth, 1)
        XCTAssertEqual(style(of: "word", in: document)?.bold, true)
    }

    func testListContinuationDoesNotRepeatBullet() {
        let document = MarkdownDocument(source: "- First\n\n  Continued paragraph\n\n  > quoted child\n\n- Second")
        XCTAssertEqual(document.text, "• First\n\nContinued paragraph\n\nquoted child\n• Second")
        XCTAssertEqual(style(of: "Continued paragraph", in: document)?.listDepth, 1)
        XCTAssertEqual(style(of: "quoted child", in: document)?.quoteDepth, 1)
    }

    func testPlainLineBreaksAndMarkdownHardBreaks() {
        let document = MarkdownDocument(source: "One line\nnext line\n\nParagraph after.\n\nHard  \nbreak\\\nnext")
        XCTAssertEqual(document.text, "One line\nnext line\n\nParagraph after.\n\nHard\nbreak\nnext")
        XCTAssertEqual(document.text, document.trackingText)
    }

    func testWindowsLineEndingsRenderAsNormalLineBreaks() {
        let document = MarkdownDocument(source: "# Welcome\r\n\r\nFirst line\r\nsecond line\r\n\r\n> Quoted **words**.\r\n\r\n1. Final item")
        XCTAssertEqual(document.text, "Welcome\n\nFirst line\nsecond line\n\nQuoted words.\n\n1. Final item")
        XCTAssertEqual(document.text.utf16.count, document.trackingText.utf16.count)
        XCTAssertFalse(document.text.contains("\r"))
        XCTAssertEqual(style(of: "words", in: document)?.bold, true)
        XCTAssertEqual(style(of: "Quoted", in: document)?.quoteDepth, 1)
    }

    func testSpeechAdvancesThroughRenderedHeadingsQuotesAndLinkedList() {
        let document = MarkdownDocument(source: "# 🎙 Welcome home\n\n> We trust the Father.\n\n1. Read [John fourteen](https://example.com/never-speak-this).\n2. **Walk** in peace 🌍.")
        var tracker = ScriptTracker(script: document.trackingText)
        XCTAssertEqual(document.text.utf16.count, document.trackingText.utf16.count)
        XCTAssertEqual(tracker.words.map(\.text), ["Welcome", "home", "We", "trust", "the", "Father", "Read", "John", "fourteen", "Walk", "in", "peace"])

        let heading = tracker.update(transcript: "welcome home")
        XCTAssertEqual(heading.position, 2)
        let quote = tracker.update(transcript: "welcome home we trust the father")
        XCTAssertEqual(quote.position, 6)
        let linkedItem = tracker.update(transcript: "welcome home we trust the father read john fourteen")
        XCTAssertEqual(linkedItem.position, 9)
        let completion = tracker.update(transcript: "welcome home we trust the father read john fourteen walk in peace")
        XCTAssertEqual(completion.position, tracker.words.count)
        XCTAssertTrue(completion.didAdvance)

        for word in tracker.words {
            XCTAssertEqual((document.text as NSString).substring(with: word.range), word.text)
        }
        XCTAssertEqual(tracker.words.last?.range, (document.text as NSString).range(of: "peace"))
    }

    func testLiteralUnmatchedAndEscapedDelimitersSurvive() {
        let document = MarkdownDocument(source: "\\# literal **unclosed\n\n2 * 3 = 6\n\n\\*not italic\\*")
        XCTAssertEqual(document.text, "# literal **unclosed\n\n2 * 3 = 6\n\n*not italic*")
        XCTAssertFalse(document.runs.contains { $0.bold || $0.italic || $0.headingLevel != nil })
    }

    func testNestedEmphasisCodeAndStrikethrough() {
        let document = MarkdownDocument(source: "***Both***, *italic*, **bold**, ~~stale~~, `**literal**`.\n\n```swift\nlet word = \"🌍\"\nprint(word)\n```\n\nLast.")
        XCTAssertEqual(document.text, "Both, italic, bold, stale, **literal**.\n\nlet word = \"🌍\"\nprint(word)\n\nLast.")
        XCTAssertEqual(style(of: "Both", in: document)?.bold, true)
        XCTAssertEqual(style(of: "Both", in: document)?.italic, true)
        XCTAssertEqual(style(of: "italic", in: document)?.italic, true)
        XCTAssertEqual(style(of: "stale", in: document)?.strikethrough, true)
        XCTAssertEqual(style(of: "**literal**", in: document)?.code, true)
        XCTAssertEqual(style(of: "let word", in: document)?.code, true)
    }

    func testUTF16StyleAndSpeechRangesStayAligned() {
        let document = MarkdownDocument(source: "# 🎙 Welcome\n\n🌍 **café 👨‍👩‍👧‍👦** and *don’t stop*.")
        XCTAssertEqual(document.text, "🎙 Welcome\n\n🌍 café 👨‍👩‍👧‍👦 and don’t stop.")
        let source = document.text as NSString
        var position = 0
        for run in document.runs {
            XCTAssertEqual(run.range.location, position)
            XCTAssertLessThanOrEqual(NSMaxRange(run.range), source.length)
            position = NSMaxRange(run.range)
        }
        XCTAssertEqual(position, source.length)
        XCTAssertEqual(style(of: "café", in: document)?.bold, true)
        XCTAssertEqual(style(of: "don’t", in: document)?.italic, true)
        for word in ScriptTracker(script: document.trackingText).words {
            XCTAssertEqual(source.substring(with: word.range), word.text)
        }
    }

    func testTableCellsAndRowsDoNotJoinWords() {
        let document = MarkdownDocument(source: "| Left | Right |\n| --- | --- |\n| hello | world |")
        XCTAssertEqual(document.text, "Left\tRight\nhello\tworld")
        XCTAssertEqual(style(of: "Left", in: document)?.bold, true)
        XCTAssertEqual(ScriptTracker(script: document.trackingText).words.map(\.text), ["Left", "Right", "hello", "world"])
    }

    func testEmptyDocumentAndThematicBreak() {
        XCTAssertEqual(MarkdownDocument(source: "").text, "")
        XCTAssertEqual(MarkdownDocument(source: "\n\n").runs, [])
        let document = MarkdownDocument(source: "First\n\n---\n\nSecond")
        XCTAssertEqual(document.text, "First\n\n⸻\n\nSecond")
        XCTAssertEqual(document.trackingText, "First\n\n \n\nSecond")
    }

    private func style(of value: String, in document: MarkdownDocument) -> MarkdownRun? {
        let range = (document.text as NSString).range(of: value)
        guard range.location != NSNotFound else {
            XCTFail("Missing rendered text: \(value)")
            return nil
        }
        return document.runs.first { NSLocationInRange(range.location, $0.range) }
    }
}
