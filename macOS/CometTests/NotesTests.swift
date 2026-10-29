import ComposableArchitecture
import XCTest

@testable import Comet

final class NotesTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)

  func testANewNoteHasNoSampleContent() {
    let note = Note(id: UUID(1), createdAt: now)
    XCTAssertEqual(note.title, "")
    XCTAssertEqual(note.content, "")
    XCTAssertNil(note.sourceURL)
    XCTAssertEqual(note.displayTitle, "Untitled")
  }

  func testDisplayTitlePrefersTheNameThenTheFirstHeading() {
    XCTAssertEqual(Note(id: UUID(1), title: " Ideas ", content: "# Other", createdAt: now).displayTitle, "Ideas")
    XCTAssertEqual(Note(id: UUID(1), content: "# Meeting notes\nBody", createdAt: now).displayTitle, "Meeting notes")
    XCTAssertEqual(Note(id: UUID(1), content: "- first item", createdAt: now).displayTitle, "first item")
  }

  func testSearchMatchesTitleContentAndSource() {
    let notes: IdentifiedArrayOf<Note> = [
      Note(id: UUID(1), title: "Alpha", content: "red fox", createdAt: now, sourceURL: URL(string: "https://a.example")),
      Note(id: UUID(2), title: "Beta", content: "blue jay", createdAt: now, sourceTitle: "Docs"),
      Note(id: UUID(3), title: "Gamma", content: "quiet", createdAt: now),
    ]
    XCTAssertEqual(Notes.matching(notes, query: "fox", sort: .title).map(\.id), [UUID(1)])
    XCTAssertEqual(Notes.matching(notes, query: "docs", sort: .title).map(\.id), [UUID(2)])
    XCTAssertEqual(Notes.matching(notes, query: "a.example", sort: .title).map(\.id), [UUID(1)])
    XCTAssertEqual(Notes.matching(notes, query: "", sort: .title).map(\.displayTitle), ["Alpha", "Beta", "Gamma"])
  }

  func testSortByModificationPutsTheNewestFirst() {
    let notes: IdentifiedArrayOf<Note> = [
      Note(id: UUID(1), title: "Old", createdAt: now, modifiedAt: now),
      Note(id: UUID(2), title: "New", createdAt: now, modifiedAt: now.addingTimeInterval(60)),
    ]
    XCTAssertEqual(Notes.matching(notes, query: "", sort: .modified).map(\.id), [UUID(2), UUID(1)])
  }

  func testASourceURLCanBeClearedWithoutDeletingTheNote() {
    var note = Note(
      id: UUID(1), title: "Kept", content: "body", createdAt: now, sourceURL: URL(string: "https://gone.example"),
      sourceTitle: "Gone")
    note.sourceURL = nil
    note.sourceTitle = nil
    XCTAssertEqual(note.content, "body")
    XCTAssertEqual(note.displayTitle, "Kept")
    XCTAssertNil(note.sourceURL)
  }

  func testNotesRoundTripThroughJSON() throws {
    let note = Note(
      id: UUID(1), title: "Spec", content: "# Hello\n[link](https://a.example)", createdAt: now,
      sourceURL: URL(string: "https://a.example/page"), sourceTitle: "Page")
    let data = try JSONEncoder().encode(IdentifiedArrayOf(uniqueElements: [note]))
    let decoded = try JSONDecoder().decode(IdentifiedArrayOf<Note>.self, from: data)
    XCTAssertEqual(decoded[id: UUID(1)], note)
  }

  func testInvalidJSONNotesAreSkippedWithoutThrowingTheFileAway() throws {
    let json = Data(
      """
      [{"id":"00000000-0000-0000-0000-000000000001","title":"Ok","content":"Hi","createdAt":1000}]
      """.utf8)
    let decoder = JSONDecoder()
    let notes = try decoder.decode([Note].self, from: json)
    XCTAssertEqual(notes.first?.displayTitle, "Ok")
    XCTAssertEqual(notes.first?.content, "Hi")
  }
}

final class NoteMarkdownTests: XCTestCase {
  func testHTMLAndScriptsAreStrippedBeforeRendering() {
    let source = "# Title\n<script>alert(1)</script><b>Bold</b>"
    XCTAssertFalse(NoteMarkdown.sanitized(source).contains("<script>"))
    XCTAssertFalse(NoteMarkdown.sanitized(source).contains("<b>"))
    XCTAssertTrue(NoteMarkdown.sanitized(source).contains("Bold"))
  }

  func testUnsafeLinksAreDropped() {
    let rendered = NoteMarkdown.attributed("[go](javascript:alert(1))\n[ok](https://comet.fish)")
    let links = rendered.runs.compactMap(\.link)
    XCTAssertEqual(links.map(\.scheme), ["https"])
    XCTAssertEqual(links.first?.host(), "comet.fish")
  }

  func testMailtoAndHttpsLinksAreKept() {
    XCTAssertTrue(NoteMarkdown.isSafe(URL(string: "https://example.com")!))
    XCTAssertTrue(NoteMarkdown.isSafe(URL(string: "http://example.com")!))
    XCTAssertTrue(NoteMarkdown.isSafe(URL(string: "mailto:a@b.test")!))
    XCTAssertFalse(NoteMarkdown.isSafe(URL(string: "file:///tmp/secret")!))
    XCTAssertFalse(NoteMarkdown.isSafe(URL(string: "javascript:alert(1)")!))
  }

  func testHeadingsListsQuotesAndCodeRender() {
    let source = """
      # Heading
      - item
      > quote
      `code`
      ```
      block
      ```
      """
    let rendered = String(NoteMarkdown.attributed(source).characters)
    XCTAssertTrue(rendered.contains("Heading"))
    XCTAssertTrue(rendered.contains("item"))
    XCTAssertTrue(rendered.contains("quote"))
    XCTAssertTrue(rendered.contains("code"))
    XCTAssertTrue(rendered.contains("block"))
  }
}

