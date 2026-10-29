import ComposableArchitecture
import Foundation

struct NoteMeta: Codable, Equatable, Sendable {
  var folderID: UUID?
  var tags: [String] = []
  var pinned = false
  var trashedAt: Date?
}

struct NoteFolder: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var parentID: UUID?
}

struct NoteTemplate: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var body: String

  static let builtIn: [NoteTemplate] = [
    NoteTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Blank", body: ""),
    NoteTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Meeting", body: "# Meeting\n\n- Date:\n- People:\n\n## Notes\n\n- \n\n## Actions\n\n- [ ] "),
    NoteTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Journal", body: "# \(Date.now.formatted(date: .abbreviated, time: .omitted))\n\n"),
    NoteTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Research", body: "# Research\n\n## Question\n\n## Sources\n\n## Notes\n\n"),
    NoteTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "Project", body: "# Project\n\n## Goal\n\n## Steps\n\n- [ ] \n\n## Open questions\n\n"),
    NoteTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, name: "Reading", body: "# Reading\n\n## Source\n\n## Excerpt\n\n> \n\n## Thoughts\n\n"),
    NoteTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, name: "Tasks", body: "# Tasks\n\n- [ ] \n- [ ] \n"),
    NoteTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!, name: "Browser session", body: "# Session\n\n## Pages\n\n## What I learned\n\n"),
  ]
}

struct NotesLibrary: Codable, Equatable, Sendable {
  var folders: [NoteFolder] = []
  var meta: [String: NoteMeta] = [:]
  var templates: [NoteTemplate] = NoteTemplate.builtIn
}

extension SharedKey where Self == FileStorageKey<NotesLibrary>.Default {
  static var notesLibrary: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "NotesLibrary.json")), default: NotesLibrary()]
  }
}

enum NoteFilter: Equatable, Sendable {
  case all, pinned, trash, folder(UUID), tag(String)
}

enum NoteStats: Equatable, Sendable {
  static func counts(_ text: String) -> (words: Int, characters: Int, minutes: Int) {
    let characters = text.count
    let words = text.split { $0.isWhitespace || $0.isNewline }.count
    let minutes = max(1, Int((Double(words) / 220).rounded(.up)))
    return (words, characters, words == 0 ? 0 : minutes)
  }
}

enum NoteLinks {
  static func tokens(in content: String) -> [String] {
    content.matches(of: /\[\[([^\]]+)\]\]/).map { String($0.1).trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  static func resolve(_ token: String, notes: [Note]) -> Note? {
    if let id = UUID(uuidString: token) { return notes.first { $0.id == id } }
    return notes.first { $0.displayTitle.compare(token, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
  }

  static func targets(in content: String, notes: [Note]) -> [Note] {
    var seen: Set<UUID> = []
    return tokens(in: content).compactMap { resolve($0, notes: notes) }.filter { seen.insert($0.id).inserted }
  }

  static func broken(in content: String, notes: [Note]) -> [String] {
    tokens(in: content).filter { resolve($0, notes: notes) == nil }
  }

  static func backlinks(to note: Note, notes: [Note]) -> [Note] {
    notes.filter { other in
      other.id != note.id && targets(in: other.content, notes: notes).contains { $0.id == note.id }
    }
  }
}

enum NoteClip {
  static func page(title: String, url: URL, excerpt: String?) -> String {
    var lines = ["# \(title)", "", "Source: \(url.absoluteString)", "Captured: \(Date.now.formatted(date: .abbreviated, time: .shortened))", ""]
    if let excerpt, !excerpt.isEmpty {
      lines.append("## Excerpt")
      lines.append("")
      lines.append(excerpt)
      lines.append("")
    }
    lines.append("## Notes")
    lines.append("")
    return lines.joined(separator: "\n")
  }

  static func append(_ excerpt: String, source: URL, to content: String) -> String {
    let block = "\n\n> \(excerpt.replacingOccurrences(of: "\n", with: "\n> "))\n>\n> Source: \(source.absoluteString)\n"
    return content + block
  }
}

enum NoteExport {
  static func markdown(_ notes: [Note]) -> String {
    notes.map { note in
      var header = "# \(note.displayTitle)\n"
      if let url = note.sourceURL { header += "\nSource: \(url.absoluteString)\n" }
      return header + "\n" + note.content
    }.joined(separator: "\n\n---\n\n")
  }
}

enum NotesOrganization {
  static func meta(for id: UUID, in library: NotesLibrary) -> NoteMeta {
    library.meta[id.uuidString] ?? NoteMeta()
  }

  static func visible(_ notes: [Note], library: NotesLibrary, filter: NoteFilter) -> [Note] {
    notes.filter { note in
      let meta = meta(for: note.id, in: library)
      switch filter {
      case .trash: return meta.trashedAt != nil
      case .all: return meta.trashedAt == nil
      case .pinned: return meta.trashedAt == nil && meta.pinned
      case let .folder(id): return meta.trashedAt == nil && meta.folderID == id
      case let .tag(tag): return meta.trashedAt == nil && meta.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
      }
    }
  }

  static func tasks(in notes: [Note]) -> [(note: Note, line: String, done: Bool)] {
    notes.flatMap { note in
      note.content.split(separator: "\n").compactMap { raw -> (Note, String, Bool)? in
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- [ ] ") { return (note, String(line.dropFirst(6)), false) }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { return (note, String(line.dropFirst(6)), true) }
        return nil
      }
    }
  }
}
