import AppKit
import ComposableArchitecture
import XCTest

@testable import Comet

final class EaselsTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)

  func testANewEaselStartsEmpty() {
    let easel = Easel(id: UUID(1), createdAt: now)
    XCTAssertTrue(easel.objects.isEmpty)
    XCTAssertEqual(easel.zoom, 1)
    XCTAssertEqual(easel.displayTitle, "Untitled")
  }

  func testEachEaselKeepsItsOwnObjects() {
    var first = Easel(id: UUID(1), createdAt: now)
    var second = Easel(id: UUID(2), createdAt: now)
    first.add(.text(id: UUID(10), at: CGPoint(x: 8, y: 8), text: "One"))
    second.add(.text(id: UUID(11), at: CGPoint(x: 4, y: 4), text: "Two"))
    XCTAssertEqual(first.objects.map(\.text), ["One"])
    XCTAssertEqual(second.objects.map(\.text), ["Two"])
  }

  func testAddingMovingResizingAndDeletingObjects() {
    var easel = Easel(id: UUID(1), createdAt: now)
    let text = CanvasObject.text(id: UUID(10), at: CGPoint(x: 20, y: 30), text: "Hi")
    easel.add(text)
    XCTAssertEqual(easel.objects[id: UUID(10)]?.x, 20)

    easel.move(UUID(10), by: 5, dy: -3)
    XCTAssertEqual(easel.objects[id: UUID(10)]?.x, 25)
    XCTAssertEqual(easel.objects[id: UUID(10)]?.y, 27)

    easel.resize(UUID(10), x: 10, y: 12, width: 80, height: 50)
    XCTAssertEqual(easel.objects[id: UUID(10)]?.width, 80)
    XCTAssertEqual(easel.objects[id: UUID(10)]?.height, 50)

    let removed = easel.delete([UUID(10)])
    XCTAssertEqual(removed.map(\.id), [UUID(10)])
    XCTAssertTrue(easel.objects.isEmpty)
  }

  func testBringToFrontChangesStackingOrder() {
    var easel = Easel(id: UUID(1), createdAt: now)
    easel.add(.text(id: UUID(10), at: .zero, text: "A"))
    easel.add(.text(id: UUID(11), at: .zero, text: "B"))
    easel.bringToFront(UUID(10))
    XCTAssertEqual(easel.objects.ids, [UUID(11), UUID(10)])
  }

  func testACaptureKeepsItsSourceURL() {
    let object = CanvasObject.capture(
      id: UUID(10), at: .zero, mediaID: UUID(20), sourceURL: URL(string: "https://a.example/page")!,
      sourceTitle: "Page", capturedAt: now, size: CGSize(width: 100, height: 80))
    XCTAssertEqual(object.kind, .capture)
    XCTAssertEqual(object.url, URL(string: "https://a.example/page"))
    XCTAssertEqual(object.title, "Page")
    XCTAssertEqual(object.mediaID, UUID(20))
    XCTAssertTrue(object.searchText?.contains("a.example") == true)
  }

  func testALinkStoresTheURLSeparatelyFromItsLabel() {
    let object = CanvasObject.link(
      id: UUID(10), at: .zero, url: URL(string: "https://comet.fish")!, title: "Comet")
    XCTAssertEqual(object.title, "Comet")
    XCTAssertEqual(object.url, URL(string: "https://comet.fish"))
    var renamed = object
    renamed.title = "Home"
    XCTAssertEqual(renamed.url, URL(string: "https://comet.fish"))
  }

  func testInvalidObjectsAreDroppedOnDecode() throws {
    var easel = Easel(id: UUID(1), title: "Board", createdAt: now)
    easel.add(.text(id: UUID(10), at: .zero, text: "Keep"))
    easel.objects.append(
      CanvasObject(
        id: UUID(11), kind: .link, x: 0, y: 0, width: 100, height: 40, url: URL(string: "javascript:alert(1)")))
    easel.objects.append(CanvasObject(id: UUID(12), kind: .image, x: 0, y: 0, width: 40, height: 40))
    let data = try JSONEncoder().encode(easel)
    let decoded = try JSONDecoder().decode(Easel.self, from: data)
    XCTAssertEqual(decoded.objects.ids, [UUID(10)])
  }

  func testCanvasRoundTripsThroughJSON() throws {
    var easel = Easel(id: UUID(1), title: "Mood", createdAt: now, originX: 12, originY: -4, zoom: 1.5)
    easel.add(.text(id: UUID(10), at: CGPoint(x: 8, y: 9), text: "# Hello"))
    easel.add(.link(id: UUID(11), at: CGPoint(x: 1, y: 2), url: URL(string: "https://a.example")!, title: "A"))
    easel.add(
      .stroke(
        id: UUID(12),
        stroke: Stroke(points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 10, y: 4)], color: 0xE8432A, width: 3)))
    let data = try JSONEncoder().encode(easel)
    let decoded = try JSONDecoder().decode(Easel.self, from: data)
    XCTAssertEqual(decoded, easel)
    XCTAssertEqual(decoded.objects[id: UUID(12)]?.stroke?.points.count, 2)
  }

  func testSearchLooksThroughTitlesAndObjectText() {
    var easel = Easel(id: UUID(1), title: "Research", createdAt: now)
    easel.add(.text(id: UUID(10), at: .zero, text: "unique-token"))
    XCTAssertEqual(Easels.matching([easel], query: "unique-token", sort: .title).map(\.id), [UUID(1)])
    XCTAssertEqual(Easels.matching([easel], query: "missing", sort: .title).map(\.id), [])
  }

  func testZoomIsClamped() {
    XCTAssertEqual(Easel.clampedZoom(0.01), Easel.minZoom)
    XCTAssertEqual(Easel.clampedZoom(20), Easel.maxZoom)
    XCTAssertEqual(Easel.clampedZoom(.nan), 1)
  }

  func testResizeRejectsNonFiniteFrames() {
    var easel = Easel(id: UUID(1), createdAt: now)
    easel.add(.text(id: UUID(10), at: .zero, text: "A"))
    easel.resize(UUID(10), x: .nan, y: 0, width: 80, height: 40)
    XCTAssertEqual(easel.objects[id: UUID(10)]?.x, 0)
  }

  func testUndoRestoresAPreviousSnapshot() {
    var easel = Easel(id: UUID(1), createdAt: now)
    easel.add(.text(id: UUID(10), at: .zero, text: "A"))
    let before = easel
    easel.add(.text(id: UUID(11), at: CGPoint(x: 4, y: 4), text: "B"))
    easel = before
    XCTAssertEqual(easel.objects.map(\.text), ["A"])
  }

  func testFittedImageSizeKeepsTheAspectRatio() {
    let image = NSImage(size: NSSize(width: 800, height: 400))
    let size = Easels.fittedSize(image, maxEdge: 200)
    XCTAssertEqual(size.width, 200)
    XCTAssertEqual(size.height, 100)
  }
}

