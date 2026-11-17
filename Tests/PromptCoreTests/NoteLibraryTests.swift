import XCTest
@testable import PromptCore

final class NoteLibraryTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "NoteLibraryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testFreshInstallStartsWithOneLibrary() {
        let libraries = NoteLibrary.load(from: freshDefaults())
        XCTAssertEqual(libraries.count, 1)
        XCTAssertEqual(libraries[0].title, "Scripts")
    }

    func testOlderSettingsKeepTheOriginalFourLibraries() {
        let defaults = freshDefaults()
        defaults.set(Data([1, 2, 3]), forKey: "sermonFolderBookmark")
        let libraries = NoteLibrary.load(from: defaults)
        XCTAssertEqual(libraries.map(\.id), ["sermons", "bibleStudies", "mensMeetings", "introductionToBible"])
        XCTAssertEqual(libraries[0].bookmarkKey, "sermonFolderBookmark")
        XCTAssertEqual(libraries[1].bookmarkKey, "bibleStudiesFolderBookmark")
        XCTAssertEqual(libraries[2].filenameFilterKey, "mensMeetingsFilenameFilter")
    }

    func testAFilterAloneAlsoKeepsTheOriginalLibraries() {
        let defaults = freshDefaults()
        defaults.set("Lesson", forKey: "introductionToBibleFilenameFilter")
        XCTAssertEqual(NoteLibrary.load(from: defaults).count, 4)
    }

    func testSavedLibrariesRoundTripInOrder() {
        let defaults = freshDefaults()
        let edited = [NoteLibrary(name: "Talks", symbol: "mic"), NoteLibrary(id: "sermons", name: "Sunday", symbol: "book")]
        NoteLibrary.save(edited, to: defaults)
        XCTAssertEqual(NoteLibrary.load(from: defaults), edited)
    }

    func testSavingAnEmptyListIsRespected() {
        let defaults = freshDefaults()
        defaults.set(Data([1]), forKey: "sermonFolderBookmark")
        NoteLibrary.save([], to: defaults)
        XCTAssertEqual(NoteLibrary.load(from: defaults), [])
    }

    func testListIsCappedAtTheMaximum() {
        let defaults = freshDefaults()
        NoteLibrary.save((0..<20).map { NoteLibrary(name: "L\($0)") }, to: defaults)
        XCTAssertEqual(NoteLibrary.load(from: defaults).count, NoteLibrary.maximumCount)
    }

    func testForgetRemovesFolderAndFilterOnly() {
        let defaults = freshDefaults()
        let library = NoteLibrary(name: "Talks")
        defaults.set(Data([1]), forKey: library.bookmarkKey)
        defaults.set("x", forKey: library.filenameFilterKey)
        defaults.set("keep", forKey: "draftScript")
        NoteLibrary.forget(library, in: defaults)
        XCTAssertNil(defaults.object(forKey: library.bookmarkKey))
        XCTAssertNil(defaults.object(forKey: library.filenameFilterKey))
        XCTAssertEqual(defaults.string(forKey: "draftScript"), "keep")
    }

    func testBlankNamesShowAPlaceholder() {
        XCTAssertEqual(NoteLibrary(name: "   ").title, "Untitled library")
        XCTAssertEqual(NoteLibrary(name: " Talks ").title, "Talks")
    }
}
