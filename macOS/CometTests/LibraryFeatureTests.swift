import ComposableArchitecture
import XCTest

@testable import Comet

final class LibraryFeatureTests: XCTestCase {
  @MainActor
  func testNotesAndEaselsAreOfferedAsLibraryCommands() {
    XCTAssertEqual(AppCommands.all.first { $0.action == "openLibrary:" && $0.tag == 2 }?.title, "View Notes…")
    XCTAssertEqual(AppCommands.all.first { $0.action == "openLibrary:" && $0.tag == 5 }?.title, "View Easels…")
    XCTAssertEqual(AppCommands.all.first { $0.action == "newNote:" }?.shortcut, "⇧⌘O")
    let shortcuts = AppCommands.all.map(\.shortcut).filter { !$0.isEmpty }
    XCTAssertEqual(shortcuts.count, Set(shortcuts).count)
  }

  func testPaneTagsStayStableForMenuItems() {
    XCTAssertEqual(LibraryFeature.Pane.downloads.rawValue, 0)
    XCTAssertEqual(LibraryFeature.Pane.spaces.rawValue, 1)
    XCTAssertEqual(LibraryFeature.Pane.notes.rawValue, 2)
    XCTAssertEqual(LibraryFeature.Pane.archive.rawValue, 3)
    XCTAssertEqual(LibraryFeature.Pane.media.rawValue, 4)
    XCTAssertEqual(LibraryFeature.Pane.easels.rawValue, 5)
  }

  @MainActor
  func testSelectingAPaneClearsTheQuery() async {
    let store = TestStore(initialState: LibraryFeature.State(pane: .downloads, query: "pdf")) {
      LibraryFeature()
    }
    await store.send(.select(.notes)) {
      $0.pane = .notes
      $0.query = ""
    }
    await store.send(.select(.easels)) {
      $0.pane = .easels
    }
    await store.send(.select(.downloads)) {
      $0.pane = .downloads
    }
  }

  private func download(_ name: String) -> Download {
    Download(
      id: name, url: URL(string: "https://comet.fish/\(name)")!, fileURL: URL(filePath: "/tmp/\(name)"),
      receivedBytes: 1, totalBytes: 1, state: .complete, startTime: Date(timeIntervalSince1970: 0))
  }

  func testASubtitleNamesTheKindOfFile() {
    XCTAssertEqual(download("a.pdf").subtitle, "PDF from comet.fish")
    XCTAssertEqual(download("a.png").subtitle, "Image from comet.fish")
    XCTAssertEqual(download("a.mp4").subtitle, "Video from comet.fish")
    XCTAssertEqual(download("a.zip").subtitle, "Download from comet.fish")
  }

  func testMediaFilesAreTheImagesAndVideosDirectlyInTheFoldersReadOnce() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder.appending(path: "nested"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["shot.png", "clip.mov", "notes.txt", ".hidden.png", "nested/deep.png"] {
      try Data().write(to: folder.appending(path: name))
    }

    let names = LibraryFeature.mediaFiles(in: [folder, folder.appending(path: "nested/..")], since: .distantPast).map(\.url.lastPathComponent).sorted()
    XCTAssertEqual(names, ["clip.mov", "shot.png"])
  }

  func testMediaFilesLeaveOutFilesCreatedBeforeTheFirstLaunch() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let firstLaunch = Date(timeIntervalSince1970: 1_000_000)
    for (name, created) in [("old.png", firstLaunch - 1), ("launch.png", firstLaunch), ("new.mov", firstLaunch + 60)] {
      let file = folder.appending(path: name)
      try Data().write(to: file)
      try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: file.path)
    }

    let names = LibraryFeature.mediaFiles(in: [folder], since: firstLaunch).map(\.url.lastPathComponent).sorted()
    XCTAssertEqual(names, ["launch.png", "new.mov"])
  }

  func testAFileSavedIntoAWatchedFolderIsReported() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var media = LibraryFeature.media(in: [folder], since: .distantPast).makeAsyncIterator()
    let first = await media.next()
    XCTAssertEqual(first?.isEmpty, true)
    // Dispatch registers the watch after the first read.
    try await Task.sleep(for: .milliseconds(200))

    try Data().write(to: folder.appending(path: "shot.png"))
    let next = await media.next()
    XCTAssertEqual(next?.map(\.url.lastPathComponent), ["shot.png"])
  }
}
