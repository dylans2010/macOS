import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

struct EaselsView: View {
  @Bindable var store: StoreOf<LibraryFeature>
  let window: StoreOf<WindowFeature>
  @Shared(.easels) private var easels
  @Shared(.selectedEaselID) private var selectedID
  @Shared(.easelSort) private var sort
  @FocusState private var titleFocused: Bool

  private var selected: Easel? {
    selectedID.flatMap(UUID.init(uuidString:)).flatMap { easels[id: $0] }
  }

  var body: some View {
    GeometryReader { proxy in
      let listWidth = min(320, max(200, proxy.size.width * 0.32))
      HStack(spacing: 0) {
        list.frame(width: listWidth, height: proxy.size.height)
        Divider().overlay(Theme.divider)
        canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .onAppear {
      if selected == nil { $selectedID.withLock { $0 = easels.first?.id.uuidString } }
    }
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        searchField
        sortMenu
        Button(action: create) {
          Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.icon)
            .frame(width: 36, height: 36).background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Easel")
        .accessibilityLabel("New Easel")
      }
      .padding(.top, 10)
      let matches = Easels.matching(easels, query: store.query, sort: sort)
      if easels.isEmpty {
        empty
      } else if matches.isEmpty {
        Text("No matching easels").font(.system(size: 14)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if sort == .title {
              ForEach(matches) { easel in row(easel) }
            } else {
              let groups = Easels.groups(matches, sort: sort, now: .now, calendar: .current)
              ForEach(groups, id: \.title) { group in
                Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                  .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 6)
                ForEach(group.easels) { easel in row(easel) }
              }
            }
          }
        }
        .scrollIndicators(.never)
      }
    }
    .padding(.horizontal, 7)
    .frame(maxHeight: .infinity)
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
      TextField("", text: $store.query, prompt: Text("Search Easels...").foregroundStyle(.secondary))
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
    .accessibilityLabel("Sort Easels")
  }

  private func row(_ easel: Easel) -> some View {
    EaselRow(easel: easel, isSelected: easel.id.uuidString == selectedID, select: { select(easel.id) }, delete: { confirmDelete(easel) })
      .contextMenu {
        Button("Rename") { select(easel.id); titleFocused = true }
        Button("Delete…") { confirmDelete(easel) }
      }
  }

  private var empty: some View {
    VStack(spacing: 10) {
      Spacer()
      Image(systemName: "square.grid.2x2").font(.system(size: 36)).foregroundStyle(.secondary)
      Text("Nothing here yet!").font(.system(size: 17, weight: .semibold))
      Text("Collect pages, images and notes on a canvas.").font(.system(size: 14)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("New Easel", action: create)
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 12).frame(height: 32)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
      Spacer()
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private var canvas: some View {
    if let easel = selected {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          TextField("Untitled", text: titleBinding(easel))
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .semibold))
            .focused($titleFocused)
            .accessibilityLabel("Easel title")
          Spacer(minLength: 0)
          Button("Show Page") { window.send(.toggleLibrary) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .accessibilityLabel("Close Easels and show the page")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
        EaselCanvas(
          easel: easel,
          space: window.spaces.selected,
          open: { url, split in
            if split, let tab = window.spaces.selected.selectedTabID {
              window.send(.tab(.openInSplit(url, beside: tab), in: window.spaces.selectedID))
            } else {
              window.send(.tab(.open(url), in: window.spaces.selectedID))
            }
          },
          toast: { window.send(.showToast($0)) })
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 10) {
        Image(systemName: "square.grid.2x2").font(.system(size: 36)).foregroundStyle(.secondary)
        Text("Select an easel").font(.system(size: 17, weight: .semibold))
        Text("Or create one to start a canvas.").font(.system(size: 14)).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func titleBinding(_ easel: Easel) -> Binding<String> {
    Binding(
      get: { easels[id: easel.id]?.title ?? easel.title },
      set: { title in Easels.update(easel.id) { $0.title = title } })
  }

  private func select(_ id: Easel.ID) {
    $selectedID.withLock { $0 = id.uuidString }
  }

  private func create() {
    Easels.create()
    titleFocused = true
  }

  private func confirmDelete(_ easel: Easel) {
    guard let window = NSApp.keyWindow else { return }
    presentModal(over: window) { dismiss in
      DeleteEaselDialog(name: easel.displayTitle, delete: { Easels.delete(easel.id) }, dismiss: dismiss)
    }
  }
}

private struct EaselRow: View {
  let easel: Easel
  let isSelected: Bool
  let select: () -> Void
  let delete: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "square.grid.2x2").font(.system(size: 14)).foregroundStyle(Theme.icon).frame(width: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(easel.displayTitle).font(.system(size: 14)).lineLimit(1)
        Text("\(easel.objects.count) \(easel.objects.count == 1 ? "object" : "objects")")
          .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
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

struct DeleteEaselDialog: View {
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
      Text("This easel and its images are deleted from this computer. This cannot be undone.")
        .font(.system(size: 14)).padding(.top, 8)
    }
    .frame(width: 450)
  }
}

struct AddLinkDialog: View {
  @State var address: String
  @State var title: String
  let save: (URL, String) -> Void
  let dismiss: () -> Void

  private var url: URL? {
    let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = URL(string: text), NoteMarkdown.isSafe(parsed) else { return nil }
    return parsed
  }

  var body: some View {
    ConfirmModal(
      confirm: "Add", isValid: url != nil,
      onConfirm: {
        guard let url else { return }
        save(url, title.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
      },
      onCancel: dismiss
    ) {
      Text("Add a Link").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      ModalField(placeholder: "https://", text: $address).padding(.top, 20)
      ModalField(placeholder: "Title", text: $title).padding(.top, 10)
    }
    .frame(width: 450)
  }
}
