import ComposableArchitecture
import SwiftUI

struct NotesView: View {
  @Bindable var store: StoreOf<LibraryFeature>
  let window: StoreOf<WindowFeature>
  @Shared(.notes) private var notes
  @Shared(.selectedNoteID) private var selectedID
  @Shared(.noteSort) private var sort
  @Shared(.notesLibrary) private var library
  @State private var filter = NoteFilter.all
  @State private var focusMode = false
  @FocusState private var titleFocused: Bool

  private var selected: Note? {
    selectedID.flatMap(UUID.init(uuidString:)).flatMap { notes[id: $0] }
  }

  var body: some View {
    HStack(spacing: 0) {
      if !focusMode {
        list
        Divider().overlay(Theme.divider)
      }
      editor
    }
    .onAppear {
      if selected == nil { $selectedID.withLock { $0 = notes.first?.id.uuidString } }
    }
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        searchField
        sortMenu
        Menu {
          Button("All notes") { filter = .all }
          Button("Pinned") { filter = .pinned }
          Button("Trash") { filter = .trash }
        } label: {
          Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.icon)
            .frame(width: 36, height: 36).background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Filter")
        Button(action: create) {
          Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.icon)
            .frame(width: 36, height: 36).background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Note")
        .accessibilityLabel("New Note")
      }
      .padding(.top, 10)
      let visible = NotesOrganization.visible(Array(notes), library: library, filter: filter)
      let matches = Notes.matching(IdentifiedArray(uniqueElements: visible), query: store.query, sort: sort)
      if notes.isEmpty {
        empty
      } else if matches.isEmpty {
        emptySearch
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if sort == .title {
              ForEach(matches) { note in row(note) }
            } else {
              let groups = Notes.groups(matches, sort: sort, now: .now, calendar: .current)
              ForEach(groups, id: \.title) { group in
                Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                  .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 6)
                ForEach(group.notes) { note in row(note) }
              }
            }
          }
        }
        .scrollIndicators(.never)
      }
    }
    .padding(.horizontal, 7)
    .frame(width: 304)
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
      TextField("", text: $store.query, prompt: Text("Search Notes...").foregroundStyle(.secondary))
        .textFieldStyle(.plain)
        .font(.system(size: 14))
    }
    .padding(.horizontal, 14)
    .frame(height: 36)
    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
  }

  private var sortMenu: some View {
    Menu {
      Picker("Sort", selection: Binding($sort)) {
        ForEach(LibraryDocumentSort.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.inline)
    } label: {
      Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.icon)
        .frame(width: 36, height: 36).background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help("Sort")
    .accessibilityLabel("Sort Notes")
  }

  private func row(_ note: Note) -> some View {
    let isSelected = note.id.uuidString == selectedID
    return NoteRow(note: note, isSelected: isSelected, select: { select(note.id) }, delete: { confirmDelete(note) })
      .contextMenu {
        Button(NotesOrganization.meta(for: note.id, in: library).pinned ? "Unpin" : "Pin") { togglePin(note.id) }
        Button("Move to Trash") { trash(note.id) }
        Button("Rename") { select(note.id); titleFocused = true }
        if note.sourceURL != nil {
          Button("Remove Page Link") { Notes.update(note.id) { $0.sourceURL = nil; $0.sourceTitle = nil } }
        }
        Divider()
        Button("Delete…") { confirmDelete(note) }
      }
  }

  private var empty: some View {
    VStack(spacing: 10) {
      Spacer()
      Image(systemName: "note.text").font(.system(size: 36)).foregroundStyle(.secondary)
      Text("Nothing here yet!").font(.system(size: 17, weight: .semibold))
      Text("Capture a thought without leaving the page.").font(.system(size: 14)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("New Note", action: create)
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 12).frame(height: 32)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
      Spacer()
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity)
  }

  private var emptySearch: some View {
    Text("No matching notes").font(.system(size: 14)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var editor: some View {
    if let note = selected {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          TextField("Untitled", text: titleBinding(note))
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .semibold))
            .focused($titleFocused)
            .accessibilityLabel("Note title")
          Spacer(minLength: 0)
          noteTools(note)
          if let url = note.sourceURL {
            Button {
              window.send(.tab(.open(url), in: window.spaces.selectedID))
            } label: {
              Label(note.sourceTitle?.isEmpty == false ? note.sourceTitle! : (note.sourceHost ?? "Page"), systemImage: "link")
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Theme.fill, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
            .contextMenu {
              Button("Open Page") { window.send(.tab(.open(url), in: window.spaces.selectedID)) }
              if let tab = window.spaces.selected.selectedTabID {
                Button("Open in Split") {
                  window.send(.tab(.openInSplit(url, beside: tab), in: window.spaces.selectedID))
                }
              }
              Button("Copy Link") { copyLink(url) }
              Button("Remove Page Link") { Notes.update(note.id) { $0.sourceURL = nil; $0.sourceTitle = nil } }
            }
          } else if let tab = window.spaces.selected.selectedTab, !window.isIncognito {
            Button {
              Notes.update(note.id) { $0.sourceURL = tab.url; $0.sourceTitle = tab.displayTitle }
            } label: {
              Label("Link Page", systemImage: "link.badge.plus").font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 28)
                .background(Theme.fill, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Associate this note with the current page")
          }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 4)
        noteMeta(note)
        MarkdownEditor(text: contentBinding(note), onChange: {})
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      VStack(spacing: 10) {
        Image(systemName: "note.text").font(.system(size: 36)).foregroundStyle(.secondary)
        Text("Select a note").font(.system(size: 17, weight: .semibold))
        Text("Or create one to start writing.").font(.system(size: 14)).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func titleBinding(_ note: Note) -> Binding<String> {
    Binding(
      get: { notes[id: note.id]?.title ?? note.title },
      set: { title in Notes.update(note.id) { $0.title = title } })
  }

  private func contentBinding(_ note: Note) -> Binding<String> {
    Binding(
      get: { notes[id: note.id]?.content ?? note.content },
      set: { content in Notes.update(note.id) { $0.content = content } })
  }

  private func select(_ id: Note.ID) {
    $selectedID.withLock { $0 = id.uuidString }
  }

  private func noteTools(_ note: Note) -> some View {
    HStack(spacing: 6) {
      Menu("Template") {
        ForEach(library.templates) { template in
          Button(template.name) { Notes.update(note.id) { $0.content = template.body; if $0.title.isEmpty { $0.title = template.name } } }
        }
      }
      .menuStyle(.borderlessButton)
      Button("Clip Page") {
        if let tab = window.spaces.selected.selectedTab {
          let clip = NoteClip.page(title: tab.displayTitle, url: tab.url, excerpt: nil)
          Notes.update(note.id) {
            $0.content = $0.content.isEmpty ? clip : NoteClip.append(tab.displayTitle, source: tab.url, to: $0.content)
            $0.sourceURL = $0.sourceURL ?? tab.url
            $0.sourceTitle = $0.sourceTitle ?? tab.displayTitle
          }
        }
      }
      Button(focusMode ? "Show List" : "Focus") { focusMode.toggle() }
        .buttonStyle(.plain)
      Button("Export") { exportAll() }
        .buttonStyle(.plain)
    }
    .font(.system(size: 12))
  }

  private func noteMeta(_ note: Note) -> some View {
    let stats = NoteStats.counts(note.content)
    let links = NoteLinks.backlinks(to: note, notes: Array(notes))
    let broken = NoteLinks.broken(in: note.content, notes: Array(notes))
    return VStack(alignment: .leading, spacing: 4) {
      Text("\(stats.words) words · \(stats.characters) characters · \(stats.minutes) min")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      if !links.isEmpty {
        Text("Backlinks: \(links.map(\.displayTitle).joined(separator: ", "))")
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
      }
      if !broken.isEmpty {
        Text("Broken links: \(broken.joined(separator: ", "))")
          .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
      }
    }
    .padding(.horizontal, 22)
    .padding(.bottom, 6)
  }

  private func togglePin(_ id: Note.ID) {
    $library.withLock { library in
      var meta = library.meta[id.uuidString] ?? NoteMeta()
      meta.pinned.toggle()
      library.meta[id.uuidString] = meta
    }
  }

  private func trash(_ id: Note.ID) {
    $library.withLock { library in
      var meta = library.meta[id.uuidString] ?? NoteMeta()
      meta.trashedAt = .now
      library.meta[id.uuidString] = meta
    }
  }

  private func exportAll() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Notes.md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? NoteExport.markdown(Array(notes)).write(to: url, atomically: true, encoding: .utf8)
  }

  private func create() {
    Notes.create()
    titleFocused = true
  }

  private func confirmDelete(_ note: Note) {
    guard let window = NSApp.keyWindow else { return }
    presentModal(over: window) { dismiss in
      DeleteNoteDialog(name: note.displayTitle, delete: { Notes.delete(note.id) }, dismiss: dismiss)
    }
  }
}

private struct NoteRow: View {
  let note: Note
  let isSelected: Bool
  let select: () -> Void
  let delete: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "note.text").font(.system(size: 14)).foregroundStyle(Theme.icon).frame(width: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(note.displayTitle).font(.system(size: 14)).lineLimit(1)
        Text(NoteMarkdown.snippet(note.content)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      if isHovering {
        Button(action: delete) {
          Image(systemName: "trash").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.icon)
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Delete")
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    .background(isSelected ? Theme.fill : isHovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .onTapGesture(perform: select)
  }
}

struct DeleteNoteDialog: View {
  let name: String
  let delete: () -> Void
  let dismiss: () -> Void

  var body: some View {
    ConfirmModal(
      confirm: "Delete", confirmFill: Color(hex: 0xE8432A), confirmKeycap: Color(hex: 0xF07A66), isValid: true,
      onConfirm: {
        delete()
        dismiss()
      },
      onCancel: dismiss
    ) {
      Text("Delete “\(name)”?").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      Text("This note is deleted from this computer. This cannot be undone.").font(.system(size: 14)).padding(.top, 8)
    }
    .frame(width: 450)
  }
}
