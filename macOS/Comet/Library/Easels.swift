import AppKit
import ComposableArchitecture
import Foundation
import OSLog
import UniformTypeIdentifiers

// A freeform canvas kept for the Library, with independently placed objects.
struct Easel: Codable, Equatable, Identifiable, Sendable {
  enum CodingKeys: String, CodingKey {
    case id, title, createdAt, modifiedAt, originX, originY, zoom, objects
  }

  let id: UUID
  var title: String
  let createdAt: Date
  var modifiedAt: Date
  var originX: Double
  var originY: Double
  var zoom: Double
  var objects: IdentifiedArrayOf<CanvasObject>

  init(
    id: UUID, title: String = "", createdAt: Date, modifiedAt: Date? = nil, originX: Double = 0, originY: Double = 0,
    zoom: Double = 1, objects: IdentifiedArrayOf<CanvasObject> = []
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt ?? createdAt
    self.originX = originX
    self.originY = originY
    self.zoom = zoom
    self.objects = objects
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    originX = try container.decodeIfPresent(Double.self, forKey: .originX) ?? 0
    originY = try container.decodeIfPresent(Double.self, forKey: .originY) ?? 0
    zoom = Self.clampedZoom(try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1)
    let decoded = (try? container.decode([CanvasObject].self, forKey: .objects)) ?? []
    objects = IdentifiedArray(uniqueElements: decoded.filter(\.isValid))
  }

  var displayTitle: String {
    let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !named.isEmpty { return named }
    if let text = objects.reversed().compactMap(\.searchText).first, !text.isEmpty {
      return String(text.prefix(80))
    }
    return "Untitled"
  }

  var searchableText: String {
    ([displayTitle] + objects.compactMap(\.searchText)).joined(separator: " ")
  }

  static let minZoom = 0.25
  static let maxZoom = 4.0

  static func clampedZoom(_ zoom: Double) -> Double {
    guard zoom.isFinite else { return 1 }
    return min(max(zoom, minZoom), maxZoom)
  }

  mutating func add(_ object: CanvasObject) {
    guard object.isValid else { return }
    objects.append(object)
  }

  mutating func move(_ id: CanvasObject.ID, by dx: Double, dy: Double) {
    guard var object = objects[id: id], dx.isFinite, dy.isFinite else { return }
    object.x += dx
    object.y += dy
    objects[id: id] = object
  }

  mutating func resize(_ id: CanvasObject.ID, x: Double, y: Double, width: Double, height: Double) {
    guard var object = objects[id: id] else { return }
    object.x = x
    object.y = y
    object.width = max(width, CanvasObject.minWidth)
    object.height = max(height, CanvasObject.minHeight)
    guard object.isValid else { return }
    objects[id: id] = object
  }

  mutating func bringToFront(_ id: CanvasObject.ID) {
    guard let object = objects[id: id] else { return }
    objects.remove(id: id)
    objects.append(object)
  }

  @discardableResult
  mutating func delete(_ ids: Set<CanvasObject.ID>) -> [CanvasObject] {
    let removed = objects.filter { ids.contains($0.id) }
    objects.removeAll { ids.contains($0.id) }
    return Array(removed)
  }
}

struct CanvasObject: Codable, Equatable, Identifiable, Sendable {
  enum CodingKeys: String, CodingKey {
    case id, kind, x, y, width, height, text, url, title, mediaID, capturedAt, stroke
  }

  enum Kind: String, Codable, Sendable {
    case text
    case link
    case image
    case capture
    case stroke
  }

  static let minWidth = 48.0
  static let minHeight = 32.0
  static let defaultTextSize = CGSize(width: 240, height: 120)
  static let defaultLinkSize = CGSize(width: 260, height: 72)
  static let defaultImageSize = CGSize(width: 280, height: 200)

  let id: UUID
  var kind: Kind
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var text: String
  var url: URL?
  var title: String
  var mediaID: UUID?
  var capturedAt: Date?
  var stroke: Stroke?

  init(
    id: UUID, kind: Kind, x: Double, y: Double, width: Double, height: Double, text: String = "", url: URL? = nil,
    title: String = "", mediaID: UUID? = nil, capturedAt: Date? = nil, stroke: Stroke? = nil
  ) {
    self.id = id
    self.kind = kind
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.text = text
    self.url = url
    self.title = title
    self.mediaID = mediaID
    self.capturedAt = capturedAt
    self.stroke = stroke
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
    x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
    y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
    width = try container.decodeIfPresent(Double.self, forKey: .width) ?? Self.minWidth
    height = try container.decodeIfPresent(Double.self, forKey: .height) ?? Self.minHeight
    text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    url = try? container.decodeIfPresent(URL.self, forKey: .url)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    mediaID = try container.decodeIfPresent(UUID.self, forKey: .mediaID)
    capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt)
    stroke = try container.decodeIfPresent(Stroke.self, forKey: .stroke)
  }

  var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

  var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
      && {
        switch kind {
        case .text: true
        case .link: url.map(NoteMarkdown.isSafe) ?? false
        case .image, .capture: mediaID != nil
        case .stroke: stroke.map { $0.points.count > 1 && $0.width > 0 } ?? false
        }
      }()
  }

  var searchText: String? {
    switch kind {
    case .text:
      let snippet = NoteMarkdown.snippet(text)
      return snippet == "Empty" ? nil : snippet
    case .link:
      let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
      return [label, url?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    case .image: return title.isEmpty ? nil : title
    case .capture: return [title, url?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    case .stroke: return nil
    }
  }

  static func text(id: UUID = UUID(), at point: CGPoint, text: String = "") -> CanvasObject {
    CanvasObject(
      id: id, kind: .text, x: point.x, y: point.y, width: defaultTextSize.width, height: defaultTextSize.height,
      text: text)
  }

  static func link(id: UUID = UUID(), at point: CGPoint, url: URL, title: String) -> CanvasObject {
    CanvasObject(
      id: id, kind: .link, x: point.x, y: point.y, width: defaultLinkSize.width, height: defaultLinkSize.height, url: url,
      title: title)
  }

  static func image(id: UUID = UUID(), at point: CGPoint, mediaID: UUID, size: CGSize) -> CanvasObject {
    CanvasObject(
      id: id, kind: .image, x: point.x, y: point.y, width: size.width, height: size.height, mediaID: mediaID)
  }

  static func capture(
    id: UUID = UUID(), at point: CGPoint, mediaID: UUID, sourceURL: URL, sourceTitle: String, capturedAt: Date,
    size: CGSize
  ) -> CanvasObject {
    CanvasObject(
      id: id, kind: .capture, x: point.x, y: point.y, width: size.width, height: size.height, url: sourceURL,
      title: sourceTitle, mediaID: mediaID, capturedAt: capturedAt)
  }

  static func stroke(id: UUID = UUID(), stroke: Stroke) -> CanvasObject {
    let bounds = stroke.bounds.insetBy(dx: -stroke.width, dy: -stroke.width)
    return CanvasObject(
      id: id, kind: .stroke, x: bounds.minX, y: bounds.minY, width: max(bounds.width, 1),
      height: max(bounds.height, 1), stroke: stroke)
  }
}

struct Stroke: Codable, Equatable, Sendable {
  var points: [StrokePoint]
  var color: UInt32
  var width: Double

  var bounds: CGRect {
    guard let first = points.first else { return .null }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for point in points.dropFirst() {
      minX = min(minX, point.x)
      maxX = max(maxX, point.x)
      minY = min(minY, point.y)
      maxY = max(maxY, point.y)
    }
    return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
  }
}

struct StrokePoint: Codable, Equatable, Sendable {
  var x: Double
  var y: Double
}

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<Easel>>.Default {
  static var easels: Self { Self[.fileStorage(URL.dataDirectory.appending(path: "Easels.json")), default: []] }
}

extension SharedKey where Self == AppStorageKey<String?> {
  static var selectedEaselID: Self { .appStorage("selectedEaselID") }
}

extension SharedKey where Self == AppStorageKey<LibraryDocumentSort>.Default {
  static var easelSort: Self { Self[.appStorage("easelSort"), default: .modified] }
}

enum Easels {
  static let mediaDirectory = URL.dataDirectory.appending(path: "EaselMedia")
  static let maxImageBytes = 15 * 1_024 * 1_024
  static let maxImageEdge: CGFloat = 4_096

  static func matching(
    _ easels: IdentifiedArrayOf<Easel>, query: String, sort: LibraryDocumentSort
  ) -> [Easel] {
    let filtered =
      query.isEmpty
      ? Array(easels)
      : easels.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
    switch sort {
    case .modified: return filtered.sorted { $0.modifiedAt > $1.modifiedAt }
    case .created: return filtered.sorted { $0.createdAt > $1.createdAt }
    case .title: return filtered.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }
  }

  static func groups(
    _ easels: [Easel], sort: LibraryDocumentSort = .modified, now: Date, calendar: Calendar
  ) -> [(title: String, easels: [Easel])] {
    let date: (Easel) -> Date = sort == .created ? { $0.createdAt } : { $0.modifiedAt }
    return LibraryFeature.groups(easels, date: date, now: now, calendar: calendar).map { ($0.title, $0.items) }
  }

  @discardableResult
  @MainActor static func create(id: UUID = UUID(), now: Date = .now) -> Easel {
    let easel = Easel(id: id, createdAt: now)
    @Shared(.easels) var easels
    @Shared(.selectedEaselID) var selected
    $easels.withLock { easels in
      easels.insert(easel, at: 0)
      return
    }
    $selected.withLock { selected in selected = easel.id.uuidString }
    return easel
  }

  @MainActor static func update(_ id: Easel.ID, now: Date = .now, touch: Bool = true, _ body: (inout Easel) -> Void) {
    @Shared(.easels) var easels
    $easels.withLock {
      guard var easel = $0[id: id] else { return }
      body(&easel)
      if touch { easel.modifiedAt = now }
      $0[id: id] = easel
    }
  }

  @MainActor static func delete(_ id: Easel.ID) {
    @Shared(.easels) var easels
    @Shared(.selectedEaselID) var selected
    let removed = $easels.withLock { $0.remove(id: id) }
    if selected == id.uuidString {
      $selected.withLock { selected in selected = easels.first?.id.uuidString }
    }
    removed?.objects.forEach { removeMedia($0.mediaID) }
  }

  static func mediaURL(_ id: UUID) -> URL {
    mediaDirectory.appending(path: "\(id.uuidString).png")
  }

  static func loadImage(_ id: UUID) -> NSImage? {
    let url = mediaURL(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return NSImage(contentsOf: url)
  }

  static func storeImage(_ image: NSImage, id: UUID = UUID()) throws -> UUID {
    guard let png = pngData(image) else { throw Failure.unreadableImage }
    guard png.count <= maxImageBytes else { throw Failure.tooLarge }
    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    try png.write(to: mediaURL(id), options: .atomic)
    return id
  }

  static func removeMedia(_ id: UUID?) {
    guard let id else { return }
    do {
      try FileManager.default.removeItem(at: mediaURL(id))
    } catch {
      Logger().error("Easel media not removed: \(error)")
    }
  }

  static func pngData(_ image: NSImage) -> Data? {
    let clamped = image.clamped(to: maxImageEdge)
    guard let tiff = clamped.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }

  static func fittedSize(_ image: NSImage, maxEdge: CGFloat = 280) -> CGSize {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return CanvasObject.defaultImageSize }
    let scale = min(maxEdge / size.width, maxEdge / size.height, 1)
    return CGSize(width: max(size.width * scale, CanvasObject.minWidth), height: max(size.height * scale, CanvasObject.minHeight))
  }

  enum Failure: Error {
    case unreadableImage
    case tooLarge
  }
}

extension NSImage {
  fileprivate func clamped(to maxEdge: CGFloat) -> NSImage {
    let longest = max(size.width, size.height)
    guard longest > maxEdge, longest > 0 else { return self }
    return scaled(toWidth: size.width >= size.height ? maxEdge : maxEdge * size.width / size.height)
  }
}
