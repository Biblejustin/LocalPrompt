import XCTest
@testable import PromptCore

final class GoogleNoteLinkTests: XCTestCase {
    func testQuotedFrontmatterAndBodyLinksRetainSourceOrder() {
        let source = """
        ---
        slides: "https://docs.google.com/presentation/d/DECK_123/edit?usp=sharing"
        handout: 'https://docs.google.com/document/d/DOC-123/edit'
        ---
        [Budget](https://docs.google.com/spreadsheets/d/SHEET_123/edit#gid=7).
        <https://drive.google.com/file/d/FILE_123/view>.
        """
        let links = GoogleNoteLink.links(in: source)
        XCTAssertEqual(links.map(\.kind), [.slides, .docs, .sheets, .drive])
        XCTAssertEqual(links.map(\.title), ["Google Slides", "Google Docs", "Google Sheets", "Google Drive"])
        XCTAssertEqual(links[0].url.absoluteString, "https://docs.google.com/presentation/d/DECK_123/edit?usp=sharing")
        XCTAssertEqual(links[2].url.absoluteString, "https://docs.google.com/spreadsheets/d/SHEET_123/edit#gid=7")
        XCTAssertEqual(links[3].url.absoluteString, "https://drive.google.com/file/d/FILE_123/view")
    }

    func testPlainURLsTrimProseAndMarkdownPunctuation() {
        let source = """
        See https://docs.google.com/presentation/d/DECK/edit, then continue.
        (https://docs.google.com/document/d/DOC/view).
        [Open](<https://drive.google.com/open?id=FILE&resourcekey=KEY> "Folder").
        """
        XCTAssertEqual(GoogleNoteLink.links(in: source).map(\.url.absoluteString), [
            "https://docs.google.com/presentation/d/DECK/edit",
            "https://docs.google.com/document/d/DOC/view",
            "https://drive.google.com/open?id=FILE&resourcekey=KEY",
        ])
    }

    func testExactDuplicatesCollapseButDifferentSlideTargetsRemain() {
        let source = """
        https://DOCS.GOOGLE.COM:443/presentation/d/DECK/present?slide=id.p1
        https://docs.google.com/presentation/d/DECK/present?slide=id.p1
        https://docs.google.com/presentation/d/DECK/present?slide=id.p2
        """
        let links = GoogleNoteLink.links(in: source)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].id, "https://docs.google.com/presentation/d/DECK/present?slide=id.p1")
        XCTAssertEqual(links[1].id, "https://docs.google.com/presentation/d/DECK/present?slide=id.p2")
    }

    func testUserRoutingPublishedDocumentsAndDriveFolders() {
        let source = """
        https://docs.google.com/presentation/u/0/d/DECK/edit
        https://docs.google.com/spreadsheets/u/2/d/SHEET/view
        https://docs.google.com/document/d/e/PUBLISHED/pub
        https://drive.google.com/drive/folders/FOLDER
        https://drive.google.com/drive/u/3/folders/OTHER_FOLDER?resourcekey=KEY
        """
        XCTAssertEqual(GoogleNoteLink.links(in: source).map(\.kind), [.slides, .sheets, .docs, .drive, .drive])
    }

    func testRejectsNonGoogleInsecureAndCredentialURLs() {
        let source = """
        http://docs.google.com/presentation/d/DECK/edit
        https://docs.google.com.evil.test/presentation/d/DECK/edit
        https://evil.test/docs.google.com/presentation/d/DECK/edit
        https://docs.google.com@evil.test/presentation/d/DECK/edit
        https://user:password@docs.google.com/presentation/d/DECK/edit
        https://drive.google.com:8443/file/d/FILE/view
        https://drive.google.com./file/d/FILE/view
        https://slides.google.com/presentation/d/DECK/edit
        """
        XCTAssertTrue(GoogleNoteLink.links(in: source).isEmpty)
    }

    func testRejectsMissingIDsAndUnrelatedServiceOrDownloadURLs() {
        let source = """
        https://docs.google.com/presentation/d/
        https://docs.google.com/spreadsheets/
        https://docs.google.com/document/d/../edit
        https://docs.google.com/document/d/ID%2FOTHER/edit
        https://docs.google.com/presentation/create
        https://docs.google.com/presentation/d/DECK/export?format=pdf
        https://drive.google.com/drive/home
        https://drive.google.com/drive/folders/
        https://drive.google.com/open
        https://drive.google.com/open?id=
        https://drive.google.com/open?id=ONE&id=TWO
        https://drive.google.com/open?id=https%3A%2F%2Fevil.test
        https://drive.google.com/uc?id=FILE&export=download
        https://www.google.com/url?q=https%3A%2F%2Fdrive.google.com%2Ffile%2Fd%2FFILE%2Fview
        """
        XCTAssertTrue(GoogleNoteLink.links(in: source).isEmpty)
    }

    func testEmptyOrUnlinkedNoteHasNoLaunchTarget() {
        XCTAssertTrue(GoogleNoteLink.links(in: "").isEmpty)
        XCTAssertTrue(GoogleNoteLink.links(in: "No Google file linked. [[next-slide]]").isEmpty)
        XCTAssertTrue(GoogleNoteLink.links(in: "[Other reference](https://example.org/)").isEmpty)
    }
}
