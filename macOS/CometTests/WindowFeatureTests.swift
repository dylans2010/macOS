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

  func testNotesAndEaselsSitBesideThePage() {
    XCTAssertEqual(WindowFeature.libraryOpenWidth(.downloads, windowWidth: 1200), WindowFeature.libraryWidth)
    XCTAssertEqual(WindowFeature.libraryOpenWidth(.spaces, windowWidth: 1200), 1200 - WindowFeature.libraryPageGutter)
    let notes = WindowFeature.libraryOpenWidth(.notes, windowWidth: 1200)
    XCTAssertGreaterThan(notes, WindowFeature.libraryWidth)
    XCTAssertLessThanOrEqual(notes, 1200 - WindowFeature.libraryBesidePage)
    XCTAssertEqual(WindowFeature.libraryOpenWidth(.notes, windowWidth: 1200), WindowFeature.libraryOpenWidth(.easels, windowWidth: 1200))
    XCTAssertGreaterThan(WindowFeature.libraryPageNarrow(.notes, open: notes, sidebar: 0), WindowFeature.libraryWidth)
    XCTAssertEqual(WindowFeature.libraryPageNarrow(.downloads, open: notes, sidebar: 0), WindowFeature.libraryWidth)
  }
}
