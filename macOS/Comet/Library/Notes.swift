import ComposableArchitecture
import Foundation

// A Markdown note kept for the Library, optionally tied to the page it was taken from.
struct Note: Codable, Equatable, Identifiable, Sendable {
  enum CodingKeys: String, CodingKey {
    case id, title, content, createdAt, modifiedAt, sourceURL, sourceTitle
  }

  let id: UUID
  var title: String
  var content: String
  let createdAt: Date
  var modifiedAt: Date
  var sourceURL: URL?
  var sourceTitle: String?

  init(
    id: UUID, title: String = "", content: String = "", createdAt: Date, modifiedAt: Date? = nil,
    sourceURL: URL? = nil, sourceTitle: String? = nil
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt ?? createdAt
    self.sourceURL = sourceURL
    self.sourceTitle = sourceTitle
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    sourceURL = Self.decodeURL(container, forKey: .sourceURL)
    sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
  }

  // The title, or the first heading or line of the body, so an unnamed note still has a row label.
  var displayTitle: String {
    let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !named.isEmpty { return named }
    if let line = content.split(whereSeparator: \.isNewline).first {
      let stripped = NoteMarkdown.plainTitle(String(line))
      if !stripped.isEmpty { return String(stripped.prefix(80)) }
    }
    return "Untitled"
  }

  var sourceHost: String? {
    sourceURL?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
  }

  private static func decodeURL(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> URL? {
    if let url = try? container.decodeIfPresent(URL.self, forKey: key), url.scheme != nil { return url }
    if let string = try? container.decodeIfPresent(String.self, forKey: key) { return URL(string: string) }
    return nil
  }
}

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<Note>>.Default {
  static var notes: Self { Self[.fileStorage(URL.dataDirectory.appending(path: "Notes.json")), default: []] }
}

extension SharedKey where Self == AppStorageKey<String?> {
  static var selectedNoteID: Self { .appStorage("selectedNoteID") }
}

extension SharedKey where Self == AppStorageKey<LibraryDocumentSort>.Default {
  static var noteSort: Self { Self[.appStorage("noteSort"), default: .modified] }
}

enum LibraryDocumentSort: String, CaseIterable, Sendable, Hashable {
  case modified
  case created
  case title

  var title: String {
    switch self {
    case .modified: "Last Edited"
    case .created: "Date Created"
    case .title: "Name"
    }
  }
}

enum Notes {
  // Newest first when sorting by a date; A–Z by the displayed title otherwise.
  static func matching(
    _ notes: IdentifiedArrayOf<Note>, query: String, sort: LibraryDocumentSort
  ) -> [Note] {
    let filtered =
      query.isEmpty
      ? Array(notes)
      : notes.filter {
        $0.displayTitle.localizedCaseInsensitiveContains(query)
          || $0.content.localizedCaseInsensitiveContains(query)
          || ($0.sourceTitle?.localizedCaseInsensitiveContains(query) ?? false)
          || ($0.sourceURL?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
      }
    switch sort {
    case .modified: return filtered.sorted { $0.modifiedAt > $1.modifiedAt }
    case .created: return filtered.sorted { $0.createdAt > $1.createdAt }
    case .title: return filtered.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }
  }

  static func groups(
    _ notes: [Note], sort: LibraryDocumentSort = .modified, now: Date, calendar: Calendar
  ) -> [(title: String, notes: [Note])] {
    let date: (Note) -> Date = sort == .created ? { $0.createdAt } : { $0.modifiedAt }
    return LibraryFeature.groups(notes, date: date, now: now, calendar: calendar).map { ($0.title, $0.items) }
  }

  @discardableResult
  @MainActor static func create(
    sourceURL: URL? = nil, sourceTitle: String? = nil, id: UUID = UUID(), now: Date = .now
  ) -> Note {
    let note = Note(id: id, createdAt: now, sourceURL: sourceURL, sourceTitle: sourceTitle)
    @Shared(.notes) var notes
    @Shared(.selectedNoteID) var selected
    $notes.withLock { notes in
      notes.insert(note, at: 0)
      return
    }
    $selected.withLock { selected in selected = note.id.uuidString }
    return note
  }

  @MainActor static func update(_ id: Note.ID, now: Date = .now, _ body: (inout Note) -> Void) {
    @Shared(.notes) var notes
    $notes.withLock {
      guard var note = $0[id: id] else { return }
      body(&note)
      note.modifiedAt = now
      $0[id: id] = note
    }
  }

  @MainActor static func delete(_ id: Note.ID) {
    @Shared(.notes) var notes
    @Shared(.selectedNoteID) var selected
    $notes.withLock { _ = $0.remove(id: id) }
    if selected == id.uuidString {
      $selected.withLock { selected in selected = notes.first?.id.uuidString }
    }
  }
}

// Markdown for notes and easel text: Foundation's parser with HTML stripped and only http(s)/mailto links kept.
enum NoteMarkdown {
  static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

  static func attributed(_ source: String) -> AttributedString {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .full
    options.allowsExtendedAttributes = false
    options.failurePolicy = .returnPartiallyParsedIfPossible
    let text = sanitized(source)
    var result =
      (try? AttributedString(markdown: text, options: options, baseURL: nil))
      ?? AttributedString(text)
    for run in result.runs {
      guard let link = run.link else { continue }
      if isSafe(link) {
        result[run.range].link = link
      } else {
        result[run.range].link = nil
      }
    }
    return result
  }

  static func sanitized(_ source: String) -> String {
    var text = source.replacingOccurrences(of: "\u{0000}", with: "")
    text.replace(#/<[^>]+>/#, with: "")
    return text
  }

  static func isSafe(_ url: URL) -> Bool {
    allowedSchemes.contains(url.scheme?.lowercased() ?? "")
  }

  // The first line with heading and list markers taken off, for the row title of an unnamed note.
  static func plainTitle(_ line: String) -> String {
    var text = line.trimmingCharacters(in: .whitespaces)
    while text.hasPrefix("#") { text.removeFirst() }
    if text.hasPrefix(">") { text.removeFirst() }
    text = text.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") {
      text = String(text.dropFirst(2))
    } else if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber) {
      text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }
    return text.trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
  }

  static func snippet(_ content: String, limit: Int = 120) -> String {
    let flattened = content.split(whereSeparator: \.isNewline).map { plainTitle(String($0)) }.filter { !$0.isEmpty }
      .joined(separator: " ")
    return flattened.isEmpty ? "Empty" : String(flattened.prefix(limit))
  }
}

