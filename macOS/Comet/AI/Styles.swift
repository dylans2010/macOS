import ComposableArchitecture
import Foundation
import SwiftUI

struct SiteStyle: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var name: String
  var note: String
  var hosts: [String]
  var excludedPaths: [String]
  var css: String
  var script: String
  var scriptEnabled: Bool
  var enabled: Bool
}

enum StyleTemplate {
  static let readability = """
    html { background: #f6f1e7 !important; }
    body { max-width: 68ch; margin: 2.5rem auto !important; padding: 0 1.25rem;
      font: 19px/1.6 Georgia, serif !important; color: #1c1915 !important; }
    """
  static let width = "body { max-width: 980px; margin-inline: auto !important; }"
  static let focus = """
    body { font-size: 18px !important; line-height: 1.55 !important; }
    [class*="ad-"], [id*="ad-"], iframe[src*="doubleclick"] { display: none !important; }
    """

  static func named(_ title: String, css: String) -> SiteStyle {
    SiteStyle(
      id: UUID(), name: title, note: "", hosts: [], excludedPaths: [], css: css, script: "", scriptEnabled: false,
      enabled: false)
  }
}

enum StyleMatch {
  static func matches(_ url: URL, _ style: SiteStyle) -> Bool {
    guard style.enabled, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host()?.lowercased()
    else { return false }
    let path = url.path()
    if style.excludedPaths.contains(where: { !$0.isEmpty && path.hasPrefix($0) }) { return false }
    return style.hosts.contains { hostMatches(host, rule: $0) }
  }

  static func hostMatches(_ host: String, rule: String) -> Bool {
    let host = host.lowercased()
    let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !rule.isEmpty, rule != "*", !rule.contains("/") else { return false }
    if rule.hasPrefix("*.") {
      let apex = String(rule.dropFirst(2))
      guard !apex.isEmpty, !apex.contains("*") else { return false }
      return host == apex || host.hasSuffix("." + apex)
    }
    guard !rule.contains("*") else { return false }
    return host == rule
  }

  static func combinedCSS(_ styles: [SiteStyle], for url: URL) -> String {
    styles.filter { matches(url, $0) }.map(\.css).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n")
  }

  static func combinedScript(_ styles: [SiteStyle], for url: URL) -> String {
    styles.filter { matches(url, $0) && $0.scriptEnabled }.map(\.script)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
  }

  static func injection(css: String, script: String) -> String {
    let cssJSON = json(css)
    let scriptJSON = json(script)
    return """
      (() => {
        const css = \(cssJSON);
        let node = document.getElementById("comet-styles");
        if (!css) { if (node) node.remove(); }
        else {
          if (!node) {
            node = document.createElement("style");
            node.id = "comet-styles";
            (document.head || document.documentElement).appendChild(node);
          }
          node.textContent = css;
        }
        const source = \(scriptJSON);
        if (source) { try { (0, eval)(source); } catch (error) { return "script:" + error; } }
        return "ok";
      })()
      """
  }

  private static func json(_ text: String) -> String {
    (try? String(data: JSONSerialization.data(withJSONObject: text), encoding: .utf8)) ?? "\"\""
  }
}

extension SharedKey where Self == FileStorageKey<[SiteStyle]>.Default {
  static var siteStyles: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "Styles.json")), default: []]
  }
}

@MainActor
enum StyleEngine {
  static func apply(tab: UUID, url: URL?, loading: Bool) {
    guard !loading, let url, let contents = Engine.shared.tabs[tab] else { return }
    @Shared(.siteStyles) var styles
    let css = StyleMatch.combinedCSS(styles, for: url)
    let script = StyleMatch.combinedScript(styles, for: url)
    contents.evaluateJavaScript(StyleMatch.injection(css: css, script: script)) { _ in }
  }
}

struct StylesPane: View {
  @Shared(.siteStyles) private var styles
  @State private var selection: SiteStyle.ID?
  @State private var status: String?

  private var selected: SiteStyle? { selection.flatMap { id in styles.first { $0.id == id } } }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(styles) { style in
          Button(style.name) { selection = style.id }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: selection == style.id ? .semibold : .regular))
        }
        Button("New Style", action: add)
        Button("Readability") { add(StyleTemplate.named("Readability", css: StyleTemplate.readability)) }
        Button("Page Width") { add(StyleTemplate.named("Page Width", css: StyleTemplate.width)) }
        Button("Quieter Page") { add(StyleTemplate.named("Quieter Page", css: StyleTemplate.focus)) }
        Spacer()
      }
      .frame(width: 160)
      if let style = selected {
        editor(style)
      } else {
        Text("Styles change a site you name. They do not run on other sites, and a page cannot turn them on.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
      }
    }
    .padding(20)
    if let status { Text(status).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20) }
    }
  }

  private func editor(_ style: SiteStyle) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Name", text: binding(style.id, \.name)).textFieldStyle(.roundedBorder)
        TextField("Hosts, comma separated", text: hostsBinding(style.id)).textFieldStyle(.roundedBorder)
        Text("Use example.com or *.example.com. A blank list matches nothing.").font(.system(size: 11)).foregroundStyle(.secondary)
        TextField("Excluded paths, comma separated", text: pathsBinding(style.id)).textFieldStyle(.roundedBorder)
        TextEditor(text: binding(style.id, \.css)).font(.system(size: 12, design: .monospaced)).frame(minHeight: 120)
          .padding(4).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        Toggle("Allow this style’s JavaScript", isOn: boolBinding(style.id, \.scriptEnabled))
        Text("JavaScript runs in an isolated world, only on the hosts above, and only after you turn this on.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        if style.scriptEnabled {
          TextEditor(text: binding(style.id, \.script)).font(.system(size: 12, design: .monospaced)).frame(minHeight: 80)
            .padding(4).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
        Toggle("Enabled", isOn: boolBinding(style.id, \.enabled))
        HStack {
          Button("Duplicate") { duplicate(style) }
          Button("Delete", role: .destructive) { remove(style.id) }
        }
      }
    }
  }

  private func add() { add(StyleTemplate.named("Untitled Style", css: "")) }

  private func add(_ style: SiteStyle) {
    $styles.withLock { $0.append(style) }
    selection = style.id
  }

  private func duplicate(_ style: SiteStyle) {
    var copy = style
    copy.id = UUID()
    copy.name += " Copy"
    add(copy)
  }

  private func remove(_ id: SiteStyle.ID) {
    $styles.withLock { $0.removeAll { $0.id == id } }
    selection = nil
  }

  private func binding(_ id: SiteStyle.ID, _ key: WritableKeyPath<SiteStyle, String>) -> Binding<String> {
    Binding(get: { styles.first { $0.id == id }?[keyPath: key] ?? "" }, set: { value in
      $styles.withLock { styles in
        guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
        styles[index][keyPath: key] = value
      }
    })
  }

  private func boolBinding(_ id: SiteStyle.ID, _ key: WritableKeyPath<SiteStyle, Bool>) -> Binding<Bool> {
    Binding(get: { styles.first { $0.id == id }?[keyPath: key] ?? false }, set: { value in
      $styles.withLock { styles in
        guard let index = styles.firstIndex(where: { $0.id == id }) else { return }
        styles[index][keyPath: key] = value
      }
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
      })
  }
}
