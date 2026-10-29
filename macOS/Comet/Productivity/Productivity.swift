import AppKit
import ComposableArchitecture
import Darwin
import Foundation
import SwiftUI

struct ReadingItem: Codable, Equatable, Identifiable, Sendable {
  enum Status: String, Codable, Sendable { case unread, reading, done }
  var id: UUID
  var title: String
  var url: URL
  var status: Status
  var added: Date
}

struct WebApp: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var url: URL
}

struct LocalProject: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var url: URL
}

struct SessionSnapshot: Codable, Equatable, Identifiable, Sendable {
  struct Page: Codable, Equatable, Sendable {
    var url: URL
    var title: String
    var pinned: Bool
  }

  var id: UUID
  var name: String
  var created: Date
  var pages: [Page]
}

struct AgentWorkflow: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var prompt: String
}

struct SearchAlias: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var keyword: String
  var template: String
}

struct ProductivityLibrary: Codable, Equatable, Sendable {
  var reading: [ReadingItem] = []
  var apps: [WebApp] = []
  var projects: [LocalProject] = []
  var snapshots: [SessionSnapshot] = []
  var workflows: [AgentWorkflow] = []
  var aliases: [SearchAlias] = []
}

extension SharedKey where Self == FileStorageKey<ProductivityLibrary>.Default {
  static var productivity: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "Productivity.json")), default: ProductivityLibrary()]
  }
}

enum SearchAliases {
  static func destination(for query: String, aliases: [SearchAlias]) -> URL? {
    let parts = query.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2 else { return nil }
    let keyword = String(parts[0]).lowercased()
    guard let alias = aliases.first(where: { $0.keyword.lowercased() == keyword }), alias.template.contains("%s") else { return nil }
    let term = String(parts[1]).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    guard let url = URL(string: alias.template.replacingOccurrences(of: "%s", with: term)),
      let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
    else { return nil }
    return url
  }

  static func destination(for query: String) -> URL? {
    @Shared(.productivity) var library
    return destination(for: query, aliases: library.aliases)
  }
}

enum SensitiveText {
  static func redact(_ text: String) -> String {
    var output = text
    let patterns = [
      #"sk-[A-Za-z0-9]{12,}"#,
      #"Bearer [A-Za-z0-9._\-]{8,}"#,
      #"(?i)(api[_-]?key|password|secret)\s*[:=]\s*\S+"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(output.startIndex..., in: output)
      output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "[redacted]")
    }
    return output
  }

  static func redacted(_ request: AIRequest) -> AIRequest {
    var copy = request
    copy.prompt = redact(request.prompt)
    copy.system = redact(request.system)
    return copy
  }
}

enum Hibernation {
  static func allowed(live: Bool, unpinned: Bool, audible: Bool, loading: Bool, split: Bool) -> Bool {
    live && unpinned && !audible && !loading && !split
  }
}

enum ResourceMonitor {
  static func residentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return info.resident_size
  }
}

enum LocalProjectCheck {
  static func status(_ url: URL) async -> Int? {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 3
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode
    } catch {
      return nil
    }
  }
}

struct BrowserBackup: Codable, Equatable, Sendable {
  var version = 1
  var notes: [Note]
  var easels: [Easel]
  var productivity: ProductivityLibrary
}

enum BackupPackage {
  struct File: Codable, Equatable {
    var version: Int
    var checksum: String
    var payload: Data
  }

  static func encode(_ backup: BrowserBackup) throws -> Data {
    let payload = try JSONEncoder().encode(backup)
    return try JSONEncoder().encode(File(version: 1, checksum: SyncChecksum.hex(payload), payload: payload))
  }

  static func decode(_ data: Data) throws -> BrowserBackup {
    let file = try JSONDecoder().decode(File.self, from: data)
    guard SyncChecksum.hex(file.payload) == file.checksum else { throw CocoaError(.fileReadCorruptFile) }
    return try JSONDecoder().decode(BrowserBackup.self, from: file.payload)
  }
}

struct ProductivityPane: View {
  let open: (URL) -> Void
  @Shared(.productivity) private var library
  @Shared(.notes) private var notes
  @Shared(.easels) private var easels
  @State private var status = "Nothing imported yet."
  @State private var projectStatus: [UUID: String] = [:]
  @State private var keyword = ""
  @State private var template = "https://en.wikipedia.org/wiki/%s"
  @State private var memory = "Measuring…"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(memory).font(.system(size: 12)).foregroundStyle(.secondary)
        Text("This is the app’s resident memory, not a per-tab measurement. Comet cannot see each tab’s CPU.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        section("Reading queue") {
          if library.reading.isEmpty { Text("Save a page from the File menu.").foregroundStyle(.secondary) }
          ForEach(library.reading) { item in
            HStack {
              Button(item.title) { open(item.url) }.buttonStyle(.plain)
              Spacer()
              Text(item.status.rawValue).foregroundStyle(.secondary)
              Button("Done") { setReading(item.id, .done) }
              Button("Remove") { $library.withLock { $0.reading.removeAll { $0.id == item.id } } }
            }
          }
        }
        section("Web apps") {
          Text("These open as normal tabs. They are not installed Mac apps.").font(.system(size: 11)).foregroundStyle(.secondary)
          ForEach(library.apps) { app in
            HStack {
              Button(app.name) { open(app.url) }.buttonStyle(.plain)
              Spacer()
              Button("Remove") { $library.withLock { $0.apps.removeAll { $0.id == app.id } } }
            }
          }
        }
        section("Local projects") {
          Text("Checks only the addresses you save.").font(.system(size: 11)).foregroundStyle(.secondary)
          ForEach(library.projects) { project in
            HStack {
              Button(project.name) { open(project.url) }.buttonStyle(.plain)
              Spacer()
              Text(projectStatus[project.id] ?? "Not checked").foregroundStyle(.secondary)
              Button("Check") { Task { await check(project) } }
              Button("Remove") { $library.withLock { $0.projects.removeAll { $0.id == project.id } } }
            }
          }
        }
        section("Session snapshots") {
          Text("A snapshot stores tab addresses and titles. It does not store cookies or passwords.").font(.system(size: 11)).foregroundStyle(.secondary)
          ForEach(library.snapshots) { snapshot in
            HStack {
              Text("\(snapshot.name) · \(snapshot.pages.count) pages")
              Spacer()
              Button("Open") { snapshot.pages.forEach { open($0.url) } }
              Button("Delete") { $library.withLock { $0.snapshots.removeAll { $0.id == snapshot.id } } }
            }
          }
        }
        section("Agent workflows") {
          Text("A workflow runs only when you press Run, and only while Comet is open. It uses the same approval rules as Agent.").font(.system(size: 11)).foregroundStyle(.secondary)
          ForEach(library.workflows) { workflow in
            HStack {
              Text(workflow.name)
              Spacer()
              Button("Run") { run(workflow) }
              Button("Delete") { $library.withLock { $0.workflows.removeAll { $0.id == workflow.id } } }
            }
          }
        }
        section("Search keywords") {
          HStack {
            TextField("keyword", text: $keyword).textFieldStyle(.roundedBorder)
            TextField("https://example.com/search?q=%s", text: $template).textFieldStyle(.roundedBorder)
            Button("Add") { addAlias() }
          }
          ForEach(library.aliases) { alias in
            HStack {
              Text("\(alias.keyword) → \(alias.template)").lineLimit(1)
              Spacer()
              Button("Remove") { $library.withLock { $0.aliases.removeAll { $0.id == alias.id } } }
            }
          }
        }
        HStack {
          Button("Export backup…", action: exportBackup)
          Button("Import backup…", action: importBackup)
        }
        Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      .padding(24)
      .font(.system(size: 13))
    }
    .task {
      if let bytes = ResourceMonitor.residentBytes() {
        memory = "Comet is using \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)) of resident memory."
      } else {
        memory = "Resident memory is not available from this process."
      }
    }
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 13, weight: .semibold))
      content()
    }
  }

  private func setReading(_ id: UUID, _ status: ReadingItem.Status) {
    $library.withLock { library in
      guard let index = library.reading.firstIndex(where: { $0.id == id }) else { return }
      library.reading[index].status = status
    }
  }

  private func check(_ project: LocalProject) async {
    let code = await LocalProjectCheck.status(project.url)
    projectStatus[project.id] = code.map { "HTTP \($0)" } ?? "No response"
  }

  private func addAlias() {
    let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty, template.contains("%s"), URL(string: template.replacingOccurrences(of: "%s", with: "test")) != nil else {
      status = "A keyword needs a template containing %s and an http or https address."
      return
    }
    $library.withLock { $0.aliases.append(SearchAlias(id: UUID(), keyword: word, template: template)) }
    keyword = ""
    status = "Keyword saved. Type it and a query in the Command Bar."
  }

  private func run(_ workflow: AgentWorkflow) {
    guard let controller = NSApp.keyWindow?.windowController as? WindowController else {
      status = "Open a browser window before running a workflow."
      return
    }
    controller.runSavedWorkflow(workflow.prompt)
  }

  private func exportBackup() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Comet Backup.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let backup = BrowserBackup(notes: Array(notes), easels: Array(easels), productivity: library)
    do {
      try BackupPackage.encode(backup).write(to: url, options: .atomic)
      status = "Backup written. It does not include cookies, passwords, or API keys."
    } catch {
      status = "Backup failed: \(error.localizedDescription)"
    }
  }

  private func importBackup() {
    let panel = NSOpenPanel()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let backup = try BackupPackage.decode(Data(contentsOf: url))
      $notes.withLock { notes in
        for note in backup.notes { notes[id: note.id] = note }
      }
      $easels.withLock { easels in
        for easel in backup.easels { easels[id: easel.id] = easel }
      }
      $library.withLock { $0 = backup.productivity }
      status = "Imported \(backup.notes.count) notes, \(backup.easels.count) easels, and the productivity lists. Existing items with the same id were replaced."
    } catch {
      status = "Import failed. The file is not a valid Comet backup, or its checksum does not match."
    }
  }
}
