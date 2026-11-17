import Foundation
import XCTest
@testable import PromptCore

final class ObsidianMarkdownTests: XCTestCase {
    func testFrontmatterAndWikilinksBecomeReadingTextOnlyWhenEnabled() {
        let source = "---\ntitle: Hidden metadata\ntags: [sermon]\n---\n# Welcome\n\nRead [[John 14]] and [[Long note title|the promise]]."
        let document = MarkdownDocument(source: source, obsidian: true)
        XCTAssertEqual(document.text, "Welcome\n\nRead John 14 and the promise.")
        XCTAssertEqual(style(of: "Welcome", in: document)?.headingLevel, 1)
        let ordinary = MarkdownDocument(source: source)
        XCTAssertTrue(ordinary.text.contains("Hidden metadata"))
        XCTAssertTrue(ordinary.text.contains("[[John 14]]"))
        XCTAssertEqual(ordinary, MarkdownDocument(source: source, obsidian: false))
        assertAligned(document)
    }

    func testIncompleteAndNonleadingFrontmatterRemainOrdinaryMarkdown() {
        for source in [
            "---\ntitle: Keep this unfinished note\nBody remains.",
            "Opening words.\n\n---\nBody between rules.\n\n---\nEnding words.",
            "\n---\ntitle: Not start of file\n---\nBody.",
        ] {
            XCTAssertEqual(MarkdownDocument(source: source, obsidian: true), MarkdownDocument(source: source))
        }
    }

    func testBOMWindowsFrontmatterAndMetadataCuesStayHidden() {
        let source = "\u{FEFF}---\r\ntitle: Private metadata\r\n[[next-slide]]\r\n---\r\nCafé 👨‍👩‍👧‍👦 speaks.\r\n[[next-slide]]\r\nRead [[Note|grâce aujourd’hui]]."
        let document = MarkdownDocument(source: source, obsidian: true)
        XCTAssertFalse(document.text.contains("Private"))
        XCTAssertFalse(document.text.contains("next-slide"))
        XCTAssertEqual(document.slideCues, [SlideCue(id: 0, wordPosition: 2)])
        XCTAssertEqual(ScriptTracker(script: document.trackingText).words.map(\.text), ["Café", "speaks", "Read", "grâce", "aujourd’hui"])
        assertAligned(document)
        XCTAssertEqual(MarkdownDocument(source: "---\ntitle: Empty\n...", obsidian: true).text, "")
    }

    func testFencedIndentedInlineAndEscapedExamplesStayLiteral() {
        for source in [
            "```text\n[[Note|label]]\n[[next-slide]]\n```",
            "~~~~\n[[Note|label]]\n~~~~",
            "    [[Note|label]]",
            "`[[Note|label]]`",
            "`Opening\n[[Note|label]]\nclosing`",
            "\\[[Note|label]]",
            "[[Note|label]](https://example.com)",
            "<!-- [[Note|label]] -->",
        ] {
            let document = MarkdownDocument(source: source, obsidian: true)
            XCTAssertEqual(document, MarkdownDocument(source: source), source)
            XCTAssertTrue(document.slideCues.isEmpty, source)
            assertAligned(document)
        }
        let mixed = MarkdownDocument(source: "```\n[[Note|literal]]\n```\n\nRead [[Note|spoken]].", obsidian: true)
        XCTAssertEqual(mixed.text, "[[Note|literal]]\n\nRead spoken.")
    }

    func testEmbeddedNotesRemainLiteralWithoutExpandingThem() {
        let source = "Read [[ordinary note]].\n\n![[Another note]]\n\n![[image.png|caption]]"
        let document = MarkdownDocument(source: source, obsidian: true)
        XCTAssertTrue(document.text.contains("Read ordinary note."))
        XCTAssertTrue(document.text.contains("![[Another note]]"))
        XCTAssertTrue(document.text.contains("![[image.png|caption]]"))
        assertAligned(document)
    }

    func testWikilinkLabelsPreserveSurroundingStylesAndCueWordPositions() {
        let source = "---\ntitle: Hidden words\n---\n# 🎙 [[A title|Welcome home]]\n\nRead **[[Folder/Long note#A heading|one passage]]**.\n\n[[next-slide]]\n\n> Next *[[Note|careful thought]]*."
        let document = MarkdownDocument(source: source, obsidian: true)
        XCTAssertEqual(document.text, "🎙 Welcome home\n\nRead one passage.\n\nNext careful thought.")
        XCTAssertEqual(style(of: "Welcome", in: document)?.headingLevel, 1)
        XCTAssertEqual(style(of: "one", in: document)?.bold, true)
        XCTAssertEqual(style(of: "careful", in: document)?.italic, true)
        XCTAssertEqual(style(of: "Next", in: document)?.quoteDepth, 1)
        XCTAssertEqual(document.slideCues.map(\.wordPosition), [5])
        assertAligned(document)
    }

    func testLabelsCannotIntroduceMarkdownStructureOrCues() {
        let document = MarkdownDocument(source: "[[Note|# Literal heading]]\n\n[[Note|**literal stars**]]\n\n[[Note|next-slide]]\n\nSay [[next-slide]] aloud.\n\nFinal words.\n[[next-slide]]", obsidian: true)
        XCTAssertTrue(document.text.hasPrefix("# Literal heading"))
        XCTAssertTrue(document.text.contains("**literal stars**"))
        XCTAssertFalse(document.runs.contains { $0.headingLevel != nil || $0.bold })
        XCTAssertTrue(document.text.contains("Say [[next-slide]] aloud."))
        XCTAssertEqual(document.slideCues.count, 1)
        assertAligned(document)
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
