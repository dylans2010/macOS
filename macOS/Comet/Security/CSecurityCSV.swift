import Foundation

// CSV import for Security. Pure parsing and mapping: no file access, no
// network, no Keychain, and no UI. The UI (CSecurityServiceUI) picks the
// file with NSOpenPanel, reads it locally, and hands the text here.
//
// Format rules, per RFC 4180 as exporters actually emit it:
// - Fields may be quoted; a quoted field may contain commas, newlines,
//   and doubled quotes ("") for a literal quote.
// - A bare carriage return inside a quoted field is preserved; CRLF line
//   endings are treated as one terminator.
// - The first row is a header when it names known fields; otherwise the
//   file is treated as headerless and columns are positional.
enum CSecurityCSV {
  /// One parsed row: raw column values in file order, never trimmed of
  /// meaningful inner whitespace. Empty trailing columns are kept so a
  /// missing password is a validation error, not a shifted field.
  struct Row: Equatable, Sendable {
    var columns: [String]
  }

  /// Parses the whole document. Returns rows; a document that ends inside
  /// an open quote is malformed and returns nil instead of silently
  /// dropping the last record.
  static func parse(_ text: String) -> [Row]? {
    var rows: [Row] = []
    var columns: [String] = []
    var field = ""
    var inQuotes = false
    var fieldWasQuoted = false
    var index = text.startIndex

    func finishField() {
      columns.append(fieldWasQuoted ? field : field.trimmingCharacters(in: .whitespaces))
      field = ""
      fieldWasQuoted = false
    }

    while index < text.endIndex {
      let char = text[index]
      let next = text.index(after: index)
      if inQuotes {
        if char == "\"" {
          if next < text.endIndex, text[next] == "\"" {
            field.append("\"")
            index = text.index(after: next)
            continue
          }
          inQuotes = false
          index = next
          continue
        }
        field.append(char)
        index = next
        continue
      }
      switch char {
      case "\"" where field.isEmpty && !fieldWasQuoted:
        inQuotes = true
        fieldWasQuoted = true
      case ",":
        finishField()
      case "\r":
        // CRLF is one terminator; a lone CR is also a terminator.
        if next < text.endIndex, text[next] == "\n" { index = text.index(after: next) }
        finishField()
        rows.append(Row(columns: columns))
        columns = []
      case "\n":
        finishField()
        rows.append(Row(columns: columns))
        columns = []
      default:
        field.append(char)
      }
      index = next
    }
    guard !inQuotes else { return nil }
    // A final row without a trailing newline still counts, unless the
    // document was empty or ended exactly on a terminator.
    if !field.isEmpty || fieldWasQuoted || !columns.isEmpty {
      finishField()
      rows.append(Row(columns: columns))
    }
    // Blank lines (a single empty column) are not rows. A row with
    // several empty columns (",,,") is kept so validation reports it as
    // skipped with a reason instead of silently discarding it.
    return rows.filter { row in row.columns.count > 1 || row.columns.contains { !$0.isEmpty } }
  }

  // MARK: - Header mapping

  /// Which credential field a CSV column fills.
  enum Field: String, CaseIterable, Sendable {
    case name, url, username, password
  }

  /// Maps header names to fields. Recognises the headers common exporters
  /// use (Chrome, Safari, Firefox, 1Password, Bitwarden, LastPass) without
  /// assuming any one provider's schema. Unknown headers map to nil and
  /// are ignored, never guessed.
  static func field(forHeader header: String) -> Field? {
    switch header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "name", "title", "site", "website", "label": .name
    case "url", "website url", "site url", "login_uri", "uri", "address": .url
    case "username", "user", "user name", "login", "email", "email address", "account": .username
    case "password", "pass", "passwd": .password
    default: nil
    }
  }

  /// The detected mapping for a header row, plus whether the first row
  /// actually looked like a header. A header row must name at least a
  /// url and a password column; otherwise the file is headerless.
  struct Mapping: Equatable, Sendable {
    /// Column index per field, when detected.
    var columns: [Field: Int] = [:]
    var hasHeaderRow: Bool = false

    func index(for field: Field) -> Int? { columns[field] }
  }

  static func detectMapping(headerRow: Row?) -> Mapping {
    guard let headerRow else { return Mapping() }
    var mapping = Mapping()
    for (index, header) in headerRow.columns.enumerated() {
      if let field = field(forHeader: header), mapping.columns[field] == nil {
        mapping.columns[field] = index
      }
    }
    mapping.hasHeaderRow = mapping.columns[.url] != nil && mapping.columns[.password] != nil
    if !mapping.hasHeaderRow { mapping.columns = [:] }
    return mapping
  }

  /// Default positional mapping for a headerless file: name, url,
  /// username, password — the order Chrome's export uses.
  static let positionalMapping = Mapping(
    columns: [.name: 0, .url: 1, .username: 2, .password: 3], hasHeaderRow: false)

  // MARK: - Row validation

  /// The outcome for one data row. A row is never silently discarded:
  /// every non-credential row comes back as `.skipped` with a reason the
  /// import summary can show.
  enum RowOutcome: Equatable, Sendable {
    case credential(CSecurityCredential)
    case duplicate(CSecurityCredential.Metadata)
    case skipped(reason: String)
  }

  /// Validates parsed rows against a mapping and the credentials already
  /// in the vault. Duplicate means same origin + same username as an
  /// existing credential (passwords are not compared: comparing them
  /// would require decrypting every stored password for the import).
  static func validate(
    rows: [Row], mapping: Mapping, existing: [CSecurityCredential.Metadata]
  ) -> [RowOutcome] {
    rows.map { row in
      func value(_ field: Field) -> String {
        guard let index = mapping.index(for: field), index < row.columns.count else { return "" }
        return row.columns[index]
      }
      let url = value(.url)
      let username = value(.username)
      let password = value(.password)
      let name = value(.name)
      guard !url.isEmpty, !username.isEmpty, !password.isEmpty else {
        return .skipped(reason: "Missing url, username, or password.")
      }
      guard let credential = CSecurityCredential.make(
        url: url, username: username, password: password,
        displayName: name.isEmpty ? nil : name)
      else {
        return .skipped(reason: "URL has no usable website origin: \(url).")
      }
      if existing.contains(where: { $0.origin == credential.origin && $0.username == credential.username }) {
        return .duplicate(credential.metadata)
      }
      // A duplicate inside this same file is also a duplicate, not a
      // second account: same origin + username, twice.
      return .credential(credential)
    }
  }

  /// Collapses same-file duplicates (same origin + username) into one
  /// credential plus a skipped entry, preserving file order.
  static func deduplicateWithinFile(_ outcomes: [RowOutcome]) -> [RowOutcome] {
    var seen: Set<String> = []
    return outcomes.map { outcome in
      guard case let .credential(credential) = outcome else { return outcome }
      let key = credential.origin + "\n" + credential.username
      if seen.contains(key) { return .skipped(reason: "Duplicate of an earlier row in this file.") }
      seen.insert(key)
      return outcome
    }
  }
}
