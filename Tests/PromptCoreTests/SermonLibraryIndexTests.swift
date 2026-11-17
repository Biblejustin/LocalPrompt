import Foundation
import XCTest
@testable import PromptCore

final class SermonLibraryIndexTests: XCTestCase {
    private var temporary: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPromptLibraryTests-\(UUID().uuidString)", isDirectory: true)
        folder = temporary.appendingPathComponent("Sermons", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    func testRecursiveMarkdownOnlySkipsHiddenFilesPackagesAndLinks() throws {
        try write("Morning.md")
        try write("Series/Evening.MD")
        try write("notes.txt")
        try write(".hidden.md")
        try write(".obsidian/private.md")
        try write("Package.app/Contents/private.md")
        let outside = temporary.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "Outside text".write(to: outside.appendingPathComponent("Outside.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Alias.md"), withDestinationURL: outside.appendingPathComponent("Outside.md"))
        let entries = try SermonLibraryIndex.scan(folderURL: folder)
        XCTAssertEqual(Set(entries.map(\.relativePath)), ["Morning.md", "Series/Evening.MD"])
        XCTAssertEqual(Set(entries.map(\.id)), Set(entries.map(\.relativePath)))
        XCTAssertEqual(Set(entries.map(\.title)), ["Morning", "Evening"])
    }

    func testSortsNewestThenNaturalTitleWithStablePathTieBreak() throws {
        let older = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        for name in ["Sermon 10.md", "Sermon 2.md", "B/Same.md", "A/Same.md"] {
            try write(name)
            try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        try write("Newest.md")
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: folder.appendingPathComponent("Newest.md").path)
        XCTAssertEqual(try SermonLibraryIndex.scan(folderURL: folder).map(\.relativePath),
                       ["Newest.md", "A/Same.md", "B/Same.md", "Sermon 2.md", "Sermon 10.md"])
    }

    func testInvalidFolderIsAnErrorAndEmptyFolderIsValid() throws {
        XCTAssertEqual(try SermonLibraryIndex.scan(folderURL: folder), [])
        try write("File.md")
        assertError(.folderUnavailable) { _ = try SermonLibraryIndex.scan(folderURL: folder.appendingPathComponent("File.md")) }
        assertError(.folderUnavailable) { _ = try SermonLibraryIndex.scan(folderURL: folder.appendingPathComponent("Missing")) }
        assertError(.folderUnavailable) { _ = try SermonLibraryIndex.scan(folderURL: URL(string: "https://example.com/sermons")!) }
        let link = temporary.appendingPathComponent("LinkedFolder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        assertError(.symbolicLink) { _ = try SermonLibraryIndex.scan(folderURL: link) }
    }

    func testReadPreservesUTF8SourceAndReflectsManualRefresh() throws {
        let first = "---\ntitle: Sample\n---\n# Café 👋\n\n[[next-slide]]\n"
        let url = try write("Series/Message.md", text: first)
        let entry = try XCTUnwrap(SermonLibraryIndex.scan(folderURL: folder).first)
        XCTAssertEqual(try SermonLibraryIndex.read(entry, folderURL: folder), first)
        try "Updated **notes**.".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SermonLibraryIndex.read(entry, folderURL: folder), "Updated **notes**.")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Updated **notes**.")
    }

    func testReadRejectsMissingUnsupportedAndOutsideFiles() throws {
        let entryURL = try write("Gone.md")
        try FileManager.default.removeItem(at: entryURL)
        assertError(.fileUnavailable) { _ = try SermonLibraryIndex.read(fileURL: entryURL, folderURL: folder) }
        let text = try write("notes.txt")
        assertError(.unsupportedFile) { _ = try SermonLibraryIndex.read(fileURL: text, folderURL: folder) }
        let hidden = try write(".private/Message.md")
        assertError(.unsupportedFile) { _ = try SermonLibraryIndex.read(fileURL: hidden, folderURL: folder) }
        let outside = temporary.appendingPathComponent("Outside.md")
        try "Outside".write(to: outside, atomically: true, encoding: .utf8)
        assertError(.outsideFolder) { _ = try SermonLibraryIndex.read(fileURL: outside, folderURL: folder) }
        let sibling = temporary.appendingPathComponent("Sermons-Other/Note.md")
        assertError(.outsideFolder) { _ = try SermonLibraryIndex.read(fileURL: sibling, folderURL: folder) }
    }

    func testReadRejectsReplacedFileAndAncestorSymlinks() throws {
        let original = try write("Original.md")
        let nested = try write("Series/Message.md")
        let outside = temporary.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("Message.md")
        try "Outside".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
        assertError(.symbolicLink) { _ = try SermonLibraryIndex.read(fileURL: original, folderURL: folder) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Series"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Series"), withDestinationURL: outside)
        assertError(.symbolicLink) { _ = try SermonLibraryIndex.read(fileURL: nested, folderURL: folder) }
    }

    func testReadRejectsInvalidUTF8AndEnforcesByteLimit() throws {
        let invalid = folder.appendingPathComponent("Invalid.md")
        try Data([0xff, 0xfe, 0xfa]).write(to: invalid)
        assertError(.invalidUTF8) { _ = try SermonLibraryIndex.read(fileURL: invalid, folderURL: folder) }
        let limit = folder.appendingPathComponent("Limit.md")
        try Data(repeating: 0x61, count: SermonLibraryIndex.maximumFileSize).write(to: limit)
        XCTAssertEqual(try SermonLibraryIndex.read(fileURL: limit, folderURL: folder).utf8.count, SermonLibraryIndex.maximumFileSize)
        try Data(repeating: 0x61, count: SermonLibraryIndex.maximumFileSize + 1).write(to: limit)
        assertError(.fileTooLarge) { _ = try SermonLibraryIndex.read(fileURL: limit, folderURL: folder) }
    }

    @discardableResult
    private func write(_ relative: String, text: String = "Synthetic sermon notes.") throws -> URL {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func assertError(_ expected: SermonLibraryError, _ action: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(error as? SermonLibraryError, expected, file: file, line: line)
        }
    }
}
