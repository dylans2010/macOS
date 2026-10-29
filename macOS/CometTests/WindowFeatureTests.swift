import ComposableArchitecture
import XCTest

@testable import Comet

@MainActor
final class WindowFeatureTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)

  func testOpeningARowFromTheLibraryClosesItOnThatSpaceAndTab() async {
    let home = Space(id: UUID(1), name: "Home", profileID: UUID(200), createdAt: now)
    var work = Space(id: UUID(2), name: "Work", profileID: UUID(200), createdAt: now)
    work.tabs = [
      Tab(id: UUID(50), url: URL(string: "https://a.example")!, title: "A", placement: .pinned, createdAt: now, lastActiveAt: now)
    ]
    var state = WindowFeature.State(id: UUID(3), sidebar: .init(), spaces: .init(spaces: [home, work], selectedID: home.id))
    state.library = LibraryFeature.State(pane: .spaces)
    state.isLibraryOpen = true
    let store = TestStore(initialState: state) {
      WindowFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.webEngine.create = { _, _, _ in }
      $0.webEngine.load = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.openFromLibrary(UUID(2), tab: UUID(50))) { $0.isLibraryOpen = false }
    await store.skipReceivedActions()
    XCTAssertEqual(store.state.spaces.selectedID, UUID(2))
    XCTAssertEqual(store.state.spaces.selected.selectedTabID, UUID(50))
  }

  func testShowLibraryOpensNotesAndEaselsWithoutDroppingOtherPanes() async {
    var state = WindowFeature.State(
      id: UUID(3), sidebar: .init(), spaces: .init(spaces: [Space(id: UUID(1), name: "Home", profileID: UUID(200), createdAt: now)], selectedID: UUID(1)))
    state.isLibraryOpen = false
    let store = TestStore(initialState: state) { WindowFeature() }
    store.exhaustivity = .off

    await store.send(.showLibrary(.notes)) {
      $0.isLibraryOpen = true
      $0.library = LibraryFeature.State(pane: .notes)
    }
    await store.send(.showLibrary(.easels)) {
      $0.library = LibraryFeature.State(pane: .easels)
    }
    await store.send(.showLibrary(.media)) {
      $0.library = LibraryFeature.State(pane: .media)
    }
    await store.send(.showLibrary(.downloads)) {
      $0.library = LibraryFeature.State(pane: .downloads)
    }
    await store.send(.showLibrary(.spaces)) {
      $0.library = LibraryFeature.State(pane: .spaces)
    }
  }

  func testNotesAndEaselsReplaceThePage() {
    XCTAssertTrue(LibraryFeature.Pane.notes.replacesPage)
    XCTAssertTrue(LibraryFeature.Pane.easels.replacesPage)
    XCTAssertFalse(LibraryFeature.Pane.media.replacesPage)
    XCTAssertFalse(LibraryFeature.Pane.spaces.replacesPage)
    XCTAssertTrue(WindowFeature.hidesWebContent(libraryOpen: true, pane: .notes))
    XCTAssertTrue(WindowFeature.hidesWebContent(libraryOpen: true, pane: .easels))
    XCTAssertFalse(WindowFeature.hidesWebContent(libraryOpen: false, pane: .notes))
    XCTAssertFalse(WindowFeature.hidesWebContent(libraryOpen: true, pane: .media))
    XCTAssertFalse(WindowFeature.hidesWebContent(libraryOpen: true, pane: .spaces))
    XCTAssertEqual(WindowFeature.libraryOpenWidth(.notes, windowWidth: 1200), 0)
    XCTAssertEqual(WindowFeature.libraryOpenWidth(.easels, windowWidth: 800), 0)
    XCTAssertEqual(WindowFeature.libraryPageNarrow(.notes, open: 900, sidebar: 200), 0)
    XCTAssertEqual(WindowFeature.libraryOpenWidth(.downloads, windowWidth: 1200), WindowFeature.libraryWidth)
    XCTAssertEqual(WindowFeature.libraryOpenWidth(.spaces, windowWidth: 1200), 1200 - WindowFeature.libraryPageGutter)
    XCTAssertEqual(WindowFeature.libraryPageNarrow(.downloads, open: 900, sidebar: 0), WindowFeature.libraryWidth)
  }

  func testOpeningNotesKeepsAnIntentionalSplit() async {
    let now = self.now
    var home = Space(id: UUID(1), name: "Home", profileID: UUID(200), createdAt: now)
    let left = UUID(50)
    let right = UUID(51)
    home.tabs = [
      Tab(id: left, url: URL(string: "https://example.com")!, title: "Example", placement: .unpinned, createdAt: now, lastActiveAt: now),
      Tab(id: right, url: URL(string: "https://youtube.com")!, title: "Video", placement: .unpinned, createdAt: now, lastActiveAt: now),
    ]
    home.selectedTabID = left
    home.splits = [Split(id: UUID(9), tabIDs: [left, right], widths: [0.5, 0.5])]
    let state = WindowFeature.State(id: UUID(3), sidebar: .init(), spaces: .init(spaces: [home], selectedID: home.id))
    let store = TestStore(initialState: state) { WindowFeature() }
    store.exhaustivity = .off
    await store.send(.showLibrary(.notes)) {
      $0.isLibraryOpen = true
      $0.library = LibraryFeature.State(pane: .notes)
    }
    XCTAssertEqual(store.state.spaces.selected.splits.map(\.tabIDs), [[left, right]])
    XCTAssertEqual(store.state.spaces.selected.selectedTabID, left)
  }
}
