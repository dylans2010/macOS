import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

private enum StyleListFilter: String, CaseIterable, Identifiable {
  case all, enabled, current
  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: "All"
    case .enabled: "Enabled"
    case .current: "This site"
    }
  }
}

struct StylesPane: View {
  @Shared(.siteStyles) private var styles
  @State private var selection: SiteStyle.ID?
  @State private var query = ""
  @State private var filter = StyleListFilter.all
  @State private var snapshot: SiteStyle?
  @State private var status: String?
  @State private var confirmDelete = false
  @State private var diagnostics = StyleDiagnostics.shared

  private var selected: SiteStyle? { selection.flatMap { id in styles.first { $0.id == id } } }
  private var currentURL: URL? { FrontBrowser.url }
  private var unsaved: Bool {
    guard let selected, let snapshot, selected.id == snapshot.id else { return false }
    return selected != snapshot
  }

  private var visible: [SiteStyle] {
    styles.filter { style in
      switch filter {
      case .all: break
      case .enabled: if !style.enabled { return false }
      case .current:
        guard let currentURL, StyleMatch.matches(currentURL, style, requiringEnabled: false) else { return false }
      }
      let haystack = (style.name + " " + style.note + " " + style.hosts.joined(separator: " ") + " " + style.css).lowercased()
      return query.isEmpty || haystack.contains(query.lowercased())
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        TextField("Search styles", text: $query).textFieldStyle(.roundedBorder)
        Picker("Filter", selection: $filter) {
          ForEach(StyleListFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        Button("New", action: { add(StyleTemplate.named("Untitled Style", css: "")) })
        Button("Import", action: importStyles)
        Button("Export") { exportStyles(styles) }.disabled(styles.isEmpty)
      }
      HStack(alignment: .top, spacing: 12) {
        list.frame(width: 180)
        if let style = selected {
          editor(style)
        } else {
          Text("Styles change a site you name. They run only on matching http and https pages, and a page cannot turn them on.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
        }
      }
      if unsaved { Text("Unsaved changes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange) }
      else if selected != nil { Text("Saved").font(.system(size: 11)).foregroundStyle(.secondary) }
      if let status { Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }
      if let message = diagnostics.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange) }
    }
    .padding(16)
    .onAppear {
      if selection == nil { select(styles.first?.id) }
    }
    .confirmationDialog("Delete this style?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { if let selection { remove(selection) } }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(visible) { style in
            Button { select(style.id) } label: {
              HStack(spacing: 6) {
                Circle().fill(style.enabled ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                Text(style.name).lineLimit(1)
                Spacer(minLength: 0)
                if let currentURL, StyleMatch.matches(currentURL, style) {
                  Text("On").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                }
              }
              .font(.system(size: 12, weight: selection == style.id ? .semibold : .regular))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(style.name)\(style.enabled ? ", enabled" : ", disabled")")
          }
        }
      }
      HStack {
        Button("Readability") { addTemplate("Readability", StyleTemplate.readability) }
        Button("Width") { addTemplate("Page Width", StyleTemplate.width) }
        Button("Quiet") { addTemplate("Quieter Page", StyleTemplate.focus) }
      }
      .font(.system(size: 11))
      Text("Later styles override earlier ones when rules tie.")
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }
  }

  private func editor(_ style: SiteStyle) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Name", text: binding(style.id, \.name)).textFieldStyle(.roundedBorder).accessibilityLabel("Style name")
        TextField("Description", text: binding(style.id, \.note)).textFieldStyle(.roundedBorder).accessibilityLabel("Style description")
        TextField("Sites", text: hostsBinding(style.id)).textFieldStyle(.roundedBorder).accessibilityLabel("Sites")
        Text("example.com, *.example.com, or https://example.com/docs*. A blank list matches nothing.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        TextField("Excluded paths", text: pathsBinding(style.id)).textFieldStyle(.roundedBorder)
        CSSEditor(text: binding(style.id, \.css)).frame(minHeight: 180)
        let issues = CSSValidation.issues(in: style.css)
        if !issues.isEmpty {
          Text(issues.joined(separator: " ")).font(.system(size: 11)).foregroundStyle(.orange).accessibilityLabel("CSS problems")
        }
        Toggle("Enabled", isOn: boolBinding(style.id, \.enabled))
        Toggle("Allow this style’s JavaScript", isOn: boolBinding(style.id, \.scriptEnabled))
        Text("JavaScript runs in an isolated world, only on the sites above, and only after you turn this on. It runs once per page.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        if style.scriptEnabled {
          TextEditor(text: binding(style.id, \.script))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 70)
            .padding(4)
            .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Style JavaScript")
        }
        HStack {
          Button("Save") { checkpoint() }.disabled(!unsaved).keyboardShortcut("s", modifiers: .command)
          Button("Revert") { revert() }.disabled(!unsaved)
          Button("Apply") { StyleEngine.applyAll(); status = "Applied to open pages." }
          Spacer()
          Button("Up") { move(style.id, by: -1) }
          Button("Down") { move(style.id, by: 1) }
          Button("Duplicate") { duplicate(style) }
          Button("Delete", role: .destructive) { confirmDelete = true }
        }
        Button("Export This Style") { exportStyles([style]) }
        Button("Export UserCSS") { exportUserCSS(style) }
      }
    }
  }

  private func select(_ id: SiteStyle.ID?) {
    selection = id
    snapshot = id.flatMap { value in styles.first { $0.id == value } }
  }

  private func addTemplate(_ name: String, _ css: String) {
    var style = StyleTemplate.named(name, css: css)
    if let host = currentURL?.host()?.lowercased() {
      style.hosts = [host]
      style.enabled = true
      status = "\(name) is on for \(host)."
    } else {
      status = "\(name) was added turned off. Name a site before it can change a page."
    }
    add(style)
  }

  private func add(_ style: SiteStyle) {
    $styles.withLock { $0.append(style) }
    select(style.id)
    StyleEngine.applyAllSoon()
  }

  private func duplicate(_ style: SiteStyle) {
    var copy = style
    copy.id = UUID()
    copy.name += " Copy"
    copy.enabled = false
    add(copy)
  }

  private func remove(_ id: SiteStyle.ID) {
    $styles.withLock { $0.removeAll { $0.id == id } }
    select(styles.first?.id)
    StyleEngine.applyAll()
  }

  private func move(_ id: SiteStyle.ID, by delta: Int) {
    $styles.withLock { styles in
      guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
      let next = index + delta
      guard styles.indices.contains(next) else { return }
      styles.swapAt(index, next)
    }
    StyleEngine.applyAllSoon()
  }

  private func checkpoint() {
    snapshot = selected
    StyleEngine.applyAll()
    status = "Saved."
  }

  private func revert() {
    guard let snapshot else { return }
    $styles.withLock { styles in
      guard let index = styles.firstIndex(where: { $0.id == snapshot.id }) else { return }
      styles[index] = snapshot
    }
    StyleEngine.applyAll()
    status = "Reverted."
  }

  private func binding(_ id: SiteStyle.ID, _ key: WritableKeyPath<SiteStyle, String>) -> Binding<String> {
    Binding(get: { styles.first { $0.id == id }?[keyPath: key] ?? "" }, set: { value in
      $styles.withLock { styles in
        guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
        styles[index][keyPath: key] = value
      }
      StyleEngine.applyAllSoon()
    })
  }

  private func boolBinding(_ id: SiteStyle.ID, _ key: WritableKeyPath<SiteStyle, Bool>) -> Binding<Bool> {
    Binding(get: { styles.first { $0.id == id }?[keyPath: key] ?? false }, set: { value in
      $styles.withLock { styles in
        guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
        styles[index][keyPath: key] = value
      }
      StyleEngine.applyAll()
    })
  }

  private func hostsBinding(_ id: SiteStyle.ID) -> Binding<String> {
    Binding(
      get: { styles.first { $0.id == id }?.hosts.joined(separator: ", ") ?? "" },
      set: { value in
        let hosts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        $styles.withLock { styles in
          guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
          styles[index].hosts = hosts
        }
        StyleEngine.applyAllSoon()
      })
  }

  private func pathsBinding(_ id: SiteStyle.ID) -> Binding<String> {
    Binding(
      get: { styles.first { $0.id == id }?.excludedPaths.joined(separator: ", ") ?? "" },
      set: { value in
        let paths = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        $styles.withLock { styles in
          guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
          styles[index].excludedPaths = paths
        }
        StyleEngine.applyAllSoon()
      })
  }

  private func importStyles() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json, .css, .plainText]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
    do {
      let imported = try StyleTransfer.importData(data)
      guard !imported.isEmpty else { status = "That file has no styles."; return }
      $styles.withLock { $0.append(contentsOf: imported) }
      select(imported.last?.id)
      StyleEngine.applyAll()
      status = "Imported \(imported.count) style\(imported.count == 1 ? "" : "s")."
    } catch {
      status = "That file is not a Comet style export or UserCSS."
    }
  }

  private func exportStyles(_ items: [SiteStyle]) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Comet Styles.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try StyleTransfer.exportJSON(items).write(to: url, options: .atomic)
      status = "Exported \(items.count) styles."
    } catch {
      status = "Export failed."
    }
  }

  private func exportUserCSS(_ style: SiteStyle) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.css]
    panel.nameFieldStringValue = style.name + ".user.css"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let matches = style.hosts.map { "@match \($0)" }.joined(separator: "\n")
    let text = """
      /* ==UserStyle==
      @name \(style.name)
      @description \(style.note)
      \(matches)
      ==/UserStyle== */
      \(style.css)
      """
    do {
      try Data(text.utf8).write(to: url, options: .atomic)
      status = "Exported UserCSS."
    } catch {
      status = "Export failed."
    }
  }
}

struct StyleSitePanel: View {
  @Bindable private var session = StyleSiteSession.shared
  @Shared(.siteStyles) private var styles
  @State private var diagnostics = StyleDiagnostics.shared

  private var style: SiteStyle? { session.styleID.flatMap { id in styles.first { $0.id == id } } }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(session.url?.host() ?? "Styles").font(.system(size: 14, weight: .semibold))
        Spacer()
        Button("All Styles") { StyleSiteSession.openManager() }
        Button { session.dismiss() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain)
          .accessibilityLabel("Close Styles")
      }
      if let style {
        TextField("Name", text: binding(style.id, \.name)).textFieldStyle(.roundedBorder)
        TextField("Description", text: binding(style.id, \.note)).textFieldStyle(.roundedBorder)
        Toggle("Enabled on this site", isOn: boolBinding(style.id, \.enabled))
        CSSEditor(text: binding(style.id, \.css)).frame(minHeight: 220)
        let issues = CSSValidation.issues(in: style.css)
        if !issues.isEmpty {
          Text(issues.joined(separator: " ")).font(.system(size: 11)).foregroundStyle(.orange)
        }
        HStack {
          Button("Readability") { applyTemplate(style.id, StyleTemplate.readability) }
          Button("Width") { applyTemplate(style.id, StyleTemplate.width) }
          Button("Quiet") { applyTemplate(style.id, StyleTemplate.focus) }
          Spacer()
          Button("Apply") { StyleEngine.applyAll() }
        }
        .font(.system(size: 12))
        Text("Edits are stored and applied to this site. Other sites are unchanged.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        if let message = diagnostics.message {
          Text(message).font(.system(size: 11)).foregroundStyle(.orange)
        }
      }
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Styles for this site")
  }

  private func applyTemplate(_ id: SiteStyle.ID, _ css: String) {
    $styles.withLock { styles in
      guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
      styles[index].css = css
      styles[index].enabled = true
    }
    StyleEngine.applyAll()
  }

  private func binding(_ id: SiteStyle.ID, _ key: WritableKeyPath<SiteStyle, String>) -> Binding<String> {
    Binding(get: { styles.first { $0.id == id }?[keyPath: key] ?? "" }, set: { value in
      $styles.withLock { styles in
        guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
        styles[index][keyPath: key] = value
      }
      StyleEngine.applyAllSoon()
    })
  }

  private func boolBinding(_ id: SiteStyle.ID, _ key: WritableKeyPath<SiteStyle, Bool>) -> Binding<Bool> {
    Binding(get: { styles.first { $0.id == id }?[keyPath: key] ?? false }, set: { value in
      $styles.withLock { styles in
        guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
        styles[index][keyPath: key] = value
      }
      StyleEngine.applyAll()
    })
  }
}
