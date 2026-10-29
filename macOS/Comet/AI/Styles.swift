import AppKit
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

enum CSSValidation {
  static func issues(in css: String) -> [String] {
    let text = css.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    var issues: [String] = []
    var braces = 0
    var parentheses = 0
    var line = 1
    var quote: Character?
    var comment = false
    let characters = Array(text)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\n" { line += 1 }
      if comment {
        if character == "*" && index + 1 < characters.count && characters[index + 1] == "/" {
          comment = false
          index += 2
          continue
        }
        index += 1
        continue
      }
      if quote == nil && character == "/" && index + 1 < characters.count && characters[index + 1] == "*" {
        comment = true
        index += 2
        continue
      }
      if let quote, character == "\\", index + 1 < characters.count {
        index += 2
        continue
      }
      if character == "\"" || character == "'" {
        if quote == character { quote = nil } else if quote == nil { quote = character }
        index += 1
        continue
      }
      if quote == nil {
        if character == "{" { braces += 1 }
        if character == "}" {
          braces -= 1
          if braces < 0 { issues.append("Extra } on line \(line)."); braces = 0 }
        }
        if character == "(" { parentheses += 1 }
        if character == ")" {
          parentheses -= 1
          if parentheses < 0 { issues.append("Extra ) on line \(line)."); parentheses = 0 }
        }
      }
      index += 1
    }
    if comment { issues.append("A comment is missing its closing */.") }
    if quote != nil { issues.append("A string is missing its closing quote.") }
    if braces > 0 { issues.append("\(braces) unclosed brace\(braces == 1 ? "" : "s").") }
    if parentheses > 0 { issues.append("\(parentheses) unclosed parenthesis.") }
    return issues
  }
}

enum StyleTransfer {
  static func exportJSON(_ styles: [SiteStyle]) throws -> Data {
    try JSONEncoder().encode(styles)
  }

  static func importData(_ data: Data) throws -> [SiteStyle] {
    if let styles = try? JSONDecoder().decode([SiteStyle].self, from: data) { return styles }
    if let wrapped = try? JSONDecoder().decode([String: [SiteStyle]].self, from: data), let styles = wrapped["styles"] {
      return styles
    }
    if let text = String(data: data, encoding: .utf8), let style = userCSS(text) { return [style] }
    throw StyleImportError.unreadable
  }

  static func userCSS(_ text: String) -> SiteStyle? {
    guard let start = text.range(of: "==UserStyle=="), let end = text.range(of: "==/UserStyle=="), start.upperBound <= end.lowerBound else {
      let css = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !css.isEmpty, css.contains("{") else { return nil }
      return SiteStyle(
        id: UUID(), name: "Imported CSS", note: "", hosts: [], excludedPaths: [], css: css, script: "", scriptEnabled: false, enabled: false)
    }
    let header = text[start.upperBound..<end.lowerBound]
    let css = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    var name = "Imported Style"
    var note = ""
    var hosts: [String] = []
    for raw in header.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("@") else { continue }
      let body = line.dropFirst()
      if body.hasPrefix("name ") { name = String(body.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
      else if body.hasPrefix("description ") { note = String(body.dropFirst(12)).trimmingCharacters(in: .whitespaces) }
      else if body.hasPrefix("match ") { hosts.append(String(body.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
    }
    guard !name.isEmpty else { return nil }
    return SiteStyle(
      id: UUID(), name: name, note: note, hosts: hosts, excludedPaths: [], css: css, script: "", scriptEnabled: false, enabled: !hosts.isEmpty)
  }
}

enum StyleImportError: Error { case unreadable }

enum StyleMatch {
  static func matches(_ url: URL, _ style: SiteStyle, requiringEnabled: Bool = true) -> Bool {
    guard !requiringEnabled || style.enabled else { return false }
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else { return false }
    let path = url.path()
    if style.excludedPaths.contains(where: { excludes(path, $0) }) { return false }
    return style.hosts.contains { ruleMatches(url, rule: $0) }
  }

  static func excludes(_ path: String, _ excluded: String) -> Bool {
    var rule = excluded.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rule.isEmpty else { return false }
    if !rule.hasPrefix("/") { rule = "/" + rule }
    if rule.count > 1 && rule.hasSuffix("/") { rule.removeLast() }
    return path == rule || path.hasPrefix(rule + "/")
  }

  static func ruleMatches(_ url: URL, rule: String) -> Bool {
    let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rule.isEmpty else { return false }
    if rule.contains("://") { return urlPattern(url, rule) }
    guard let host = url.host()?.lowercased() else { return false }
    return hostMatches(host, rule: rule)
  }

  static func urlPattern(_ url: URL, _ rule: String) -> Bool {
    guard let schemeSep = rule.range(of: "://") else { return false }
    let scheme = String(rule[..<schemeSep.lowerBound]).lowercased()
    let pageScheme = url.scheme?.lowercased() ?? ""
    if scheme != "*" && scheme != pageScheme { return false }
    let rest = String(rule[schemeSep.upperBound...])
    let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    let hostRule = String(parts.first ?? "")
    guard let host = url.host()?.lowercased(), hostMatches(host, rule: hostRule) else { return false }
    guard parts.count > 1 else { return true }
    var pathRule = "/" + parts[1]
    if pathRule == "/*" || pathRule == "/" { return true }
    let wild = pathRule.hasSuffix("*")
    if wild { pathRule.removeLast() }
    if pathRule.isEmpty || pathRule == "/" { return true }
    if wild { return url.path().hasPrefix(pathRule) }
    return url.path() == pathRule || url.path().hasPrefix(pathRule.hasSuffix("/") ? pathRule : pathRule + "/")
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
    // A bare string is not a valid top-level JSON object and raises NSInvalidArgumentException.
    guard let data = try? JSONSerialization.data(withJSONObject: [text]),
      var encoded = String(data: data, encoding: .utf8), encoded.count >= 2
    else { return "\"\"" }
    encoded.removeFirst()
    encoded.removeLast()
    return encoded
  }
}

extension SharedKey where Self == FileStorageKey<[SiteStyle]>.Default {
  static var siteStyles: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "Styles.json")), default: []]
  }
}

@MainActor @Observable
final class StyleDiagnostics {
  static let shared = StyleDiagnostics()
  var message: String?
}

@MainActor @Observable
final class StyleSiteSession {
  static let shared = StyleSiteSession()
  var isPresented = false
  var url: URL?
  var styleID: SiteStyle.ID?

  func present(url: URL) {
    guard let host = url.host()?.lowercased(), !host.isEmpty else { return }
    @Shared(.siteStyles) var styles
    if let existing = styles.first(where: { StyleMatch.matches(url, $0, requiringEnabled: false) }) {
      styleID = existing.id
    } else {
      let style = SiteStyle(
        id: UUID(), name: host, note: "", hosts: [host], excludedPaths: [], css: "", script: "", scriptEnabled: false, enabled: true)
      $styles.withLock { $0.append(style) }
      styleID = style.id
    }
    self.url = url
    isPresented = true
  }

  func dismiss() { isPresented = false }

  static func openManager() {
    AppCommands.perform(Command(title: "Styles", symbol: "paintbrush", action: "showSettings:", tag: SettingsPane.styles.rawValue))
  }
}

enum FrontBrowser {
  @MainActor static var url: URL? {
    if let main = NSApp.mainWindow?.windowController as? WindowController {
      return main.store.spaces.selected.selectedTab?.url
    }
    return NSApp.windows.compactMap { $0.windowController as? WindowController }.first?.store.spaces.selected.selectedTab?.url
  }
}

@MainActor
enum StyleEngine {
  private static var scriptStamp: [UUID: String] = [:]
  private static var pending: Task<Void, Never>?

  static func apply(tab: UUID, url: URL?, loading: Bool) {
    guard let contents = Engine.shared.tabs[tab] else { return }
    let liveURL = contents.url ?? url
    guard !contents.isLoading, !loading, let liveURL else { return }
    @Shared(.siteStyles) var styles
    let css = StyleMatch.combinedCSS(styles, for: liveURL)
    let script = StyleMatch.combinedScript(styles, for: liveURL)
    let stamp = liveURL.absoluteString + "\n" + script
    let runScript = !script.isEmpty && scriptStamp[tab] != stamp
    if runScript { scriptStamp[tab] = stamp }
    contents.evaluateJavaScript(StyleMatch.injection(css: css, script: runScript ? script : "")) { result in
      Task { @MainActor in
        if result == nil, runScript { StyleEngine.scriptStamp[tab] = nil }
        if let result, result.hasPrefix("script:") {
          StyleDiagnostics.shared.message = "Style JavaScript failed: \(result.dropFirst("script:".count))"
        } else if result == nil {
          StyleDiagnostics.shared.message = "Styles could not be injected. The page was not ready."
        } else if StyleDiagnostics.shared.message != nil {
          StyleDiagnostics.shared.message = nil
        }
      }
    }
  }

  static func applyAll() {
    let live = Set(Engine.shared.tabs.keys)
    scriptStamp = scriptStamp.filter { live.contains($0.key) }
    for (tab, contents) in Engine.shared.tabs {
      apply(tab: tab, url: contents.url, loading: contents.isLoading)
    }
  }

  static func applyAllSoon() {
    pending?.cancel()
    pending = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(220))
      guard !Task.isCancelled else { return }
      applyAll()
    }
  }
}

// StylesPane and StyleSitePanel live in StylesUI.swift.
