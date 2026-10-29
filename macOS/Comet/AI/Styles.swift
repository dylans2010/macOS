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
  var schema: Int
  var theme: StyleTheme
  var color: StyleColor?
  var contrast: Double
  var brightness: Double
  var saturation: Double
  var fontID: String?
  var textScale: Double
  var textCase: StyleTextCase
  var hidden: [StyleHidden]
  var visualsEnabled: Bool
  var recolorBoxes: Bool
  var created: Date
  var modified: Date

  var hasAdjustments: Bool {
    !StyleLimits.near(contrast, 1) || !StyleLimits.near(brightness, 1) || !StyleLimits.near(saturation, 1)
  }

  init(
    id: UUID, name: String, note: String = "", hosts: [String] = [], excludedPaths: [String] = [], css: String = "",
    script: String = "", scriptEnabled: Bool = false, enabled: Bool = false, schema: Int = 2, theme: StyleTheme = .website,
    color: StyleColor? = nil, contrast: Double = 1, brightness: Double = 1, saturation: Double = 1, fontID: String? = nil,
    textScale: Double = 1, textCase: StyleTextCase = .original, hidden: [StyleHidden] = [], visualsEnabled: Bool = true,
    recolorBoxes: Bool = false, created: Date = Date(), modified: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.note = note
    self.hosts = hosts
    self.excludedPaths = excludedPaths
    self.css = css
    self.script = script
    self.scriptEnabled = scriptEnabled
    self.enabled = enabled
    self.schema = schema
    self.theme = theme
    self.color = color
    self.contrast = StyleLimits.contrast(contrast)
    self.brightness = StyleLimits.brightness(brightness)
    self.saturation = StyleLimits.saturation(saturation)
    self.fontID = fontID
    self.textScale = StyleLimits.scale(textScale)
    self.textCase = textCase
    self.hidden = hidden
    self.visualsEnabled = visualsEnabled
    self.recolorBoxes = recolorBoxes
    self.created = created
    self.modified = modified
  }

  mutating func resetVisuals() {
    theme = .website
    color = nil
    contrast = 1
    brightness = 1
    saturation = 1
    fontID = nil
    textScale = 1
    textCase = .original
    recolorBoxes = false
    visualsEnabled = true
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Style"
    note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
    excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
    css = try container.decodeIfPresent(String.self, forKey: .css) ?? ""
    script = try container.decodeIfPresent(String.self, forKey: .script) ?? ""
    scriptEnabled = try container.decodeIfPresent(Bool.self, forKey: .scriptEnabled) ?? false
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 1
    theme = try container.decodeIfPresent(StyleTheme.self, forKey: .theme) ?? .website
    color = try container.decodeIfPresent(StyleColor.self, forKey: .color)
    contrast = StyleLimits.contrast(try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1)
    brightness = StyleLimits.brightness(try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 1)
    saturation = StyleLimits.saturation(try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1)
    let font = try container.decodeIfPresent(String.self, forKey: .fontID)
    fontID = font?.isEmpty == false ? font : nil
    textScale = StyleLimits.scale(try container.decodeIfPresent(Double.self, forKey: .textScale) ?? 1)
    textCase = try container.decodeIfPresent(StyleTextCase.self, forKey: .textCase) ?? .original
    hidden = try container.decodeIfPresent([StyleHidden].self, forKey: .hidden) ?? []
    visualsEnabled = try container.decodeIfPresent(Bool.self, forKey: .visualsEnabled) ?? true
    recolorBoxes = try container.decodeIfPresent(Bool.self, forKey: .recolorBoxes) ?? false
    created = try container.decodeIfPresent(Date.self, forKey: .created) ?? .distantPast
    modified = try container.decodeIfPresent(Date.self, forKey: .modified) ?? created
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(note, forKey: .note)
    try container.encode(hosts, forKey: .hosts)
    try container.encode(excludedPaths, forKey: .excludedPaths)
    try container.encode(css, forKey: .css)
    try container.encode(script, forKey: .script)
    try container.encode(scriptEnabled, forKey: .scriptEnabled)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(schema, forKey: .schema)
    try container.encode(theme, forKey: .theme)
    try container.encodeIfPresent(color, forKey: .color)
    try container.encode(contrast, forKey: .contrast)
    try container.encode(brightness, forKey: .brightness)
    try container.encode(saturation, forKey: .saturation)
    try container.encodeIfPresent(fontID, forKey: .fontID)
    try container.encode(textScale, forKey: .textScale)
    try container.encode(textCase, forKey: .textCase)
    try container.encode(hidden, forKey: .hidden)
    try container.encode(visualsEnabled, forKey: .visualsEnabled)
    try container.encode(recolorBoxes, forKey: .recolorBoxes)
    try container.encode(created, forKey: .created)
    try container.encode(modified, forKey: .modified)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, note, hosts, excludedPaths, css, script, scriptEnabled, enabled, schema, theme, color
    case contrast, brightness, saturation, fontID, textScale, textCase, hidden, visualsEnabled, recolorBoxes
    case created, modified
  }
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
    styles.filter { matches(url, $0) }.map(StyleVisuals.appliedCSS).filter { !$0.isEmpty }.joined(separator: "\n")
  }

  static func combinedScript(_ styles: [SiteStyle], for url: URL) -> String {
    styles.filter { matches(url, $0) && $0.scriptEnabled }.map(\.script)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
  }

  static func scopes(_ styles: [SiteStyle], for url: URL) -> [StyleScope] {
    styles.filter { matches(url, $0) }.map { StyleScope(hosts: $0.hosts, excludedPaths: $0.excludedPaths) }
  }

  static func injection(css: String, script: String, scopes: [StyleScope] = [], runScript: Bool = false) -> String {
    StyleInjection.source(css: css, script: script, scopes: scopes, runScript: runScript)
  }
}

struct StyleInstallPlan: Equatable {
  var css: String
  var script: String
  var scopes: [StyleScope]
  var runScript: Bool
}

enum StyleApplyPlanner {
  struct Memory: Equatable {
    var pending = false
    var url: String?
    var css: String?
    var scriptKey: String?
  }

  // Loading and a changed address run the script again. A color tweak only replaces the style element.
  static func step(memory: inout Memory, loading: Bool, url: URL?, styles: [SiteStyle]) -> StyleInstallPlan? {
    if loading {
      memory.pending = true
      return nil
    }
    let key = url?.absoluteString
    let http = url.flatMap { $0.scheme?.lowercased() }.map { ["http", "https"].contains($0) } ?? false
    guard http, let url, let key else {
      memory.pending = false
      memory.url = key
      memory.css = nil
      memory.scriptKey = nil
      return nil
    }
    let css = StyleMatch.combinedCSS(styles, for: url)
    let script = StyleMatch.combinedScript(styles, for: url)
    let navigated = memory.pending || memory.url != key
    memory.pending = false
    memory.url = key
    let scriptKey = key + "\n" + script
    let runScript = navigated || memory.scriptKey != scriptKey
    if !runScript && memory.css == css { return nil }
    memory.scriptKey = scriptKey
    memory.css = css
    return StyleInstallPlan(css: css, script: script, scopes: StyleMatch.scopes(styles, for: url), runScript: runScript)
  }
}

enum StyleDraft {
  static func resolve(_ styles: [SiteStyle], draft: StyleEngine.Draft?) -> [SiteStyle] {
    guard let draft else { return styles }
    return styles.map { style in
      guard style.id == draft.styleID else { return style }
      var copy = style
      copy.css = draft.css
      copy.script = draft.script
      copy.scriptEnabled = draft.scriptEnabled
      return copy
    }
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

enum ZapPhase: Equatable {
  case idle
  case selecting
  case confirming(ZapConfirmation)
}

struct ZapConfirmation: Equatable {
  var candidates: [StyleSelector.Candidate]
  var index: Int
  var matches: Int
}

@MainActor @Observable
final class StyleSiteSession {
  static let shared = StyleSiteSession()
  var isPresented = false
  var url: URL?
  var liveURL: URL?
  var styleID: SiteStyle.ID?
  var offset = CGSize.zero
  var codeOffset = CGSize.zero
  var styleMoved = false
  var codeMoved = false
  var codeOpen = false
  var contentHeight: CGFloat = 640
  var zap: ZapPhase = .idle
  var codeCSS = ""
  var codeScript = ""
  var codeScriptEnabled = false
  var codeStyleID: SiteStyle.ID?

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
    liveURL = url
    isPresented = true
  }

  func dismiss() {
    let drafted = StyleEngine.draft != nil
    StyleZap.cancel()
    StyleEngine.draft = nil
    codeOpen = false
    isPresented = false
    if drafted { StyleEngine.applyAll() }
  }

  func styles(for page: URL?, in styles: [SiteStyle]) -> [SiteStyle] {
    guard let page else { return [] }
    return styles.filter { StyleMatch.matches(page, $0, requiringEnabled: false) }
  }

  func codeIsDirty(in styles: [SiteStyle]) -> Bool {
    guard let codeStyleID, let style = styles.first(where: { $0.id == codeStyleID }) else { return false }
    return codeCSS != style.css || codeScript != style.script || codeScriptEnabled != style.scriptEnabled
  }

  static func openManager() {
    AppCommands.perform(Command(title: "Styles", symbol: "paintbrush", action: "showSettings:", tag: SettingsPane.styles.rawValue))
  }
}

enum FrontBrowser {
  @MainActor static var controller: WindowController? {
    if let main = NSApp.mainWindow?.windowController as? WindowController { return main }
    return NSApp.windows.compactMap { $0.windowController as? WindowController }.first
  }

  @MainActor static var url: URL? { controller?.store.spaces.selected.selectedTab?.url }

  @MainActor static var tabID: UUID? { controller?.store.spaces.selected.selectedTab?.id }
}

@MainActor
enum StyleEditing {
  static func current() -> [SiteStyle] {
    @Shared(.siteStyles) var styles
    return styles
  }

  static func update(_ id: SiteStyle.ID, soon: Bool = true, _ edit: (inout SiteStyle) -> Void) {
    @Shared(.siteStyles) var styles
    $styles.withLock { items in
      guard let index = items.firstIndex(where: { $0.id == id }) else { return }
      edit(&items[index])
      items[index].modified = Date()
    }
    if soon { StyleEngine.applyAllSoon() } else { StyleEngine.applyAll() }
  }
}

@MainActor
enum StyleEngine {
  struct Draft: Equatable {
    var styleID: UUID
    var css: String
    var script: String
    var scriptEnabled: Bool
  }

  static var draft: Draft?
  private static var memory: [UUID: StyleApplyPlanner.Memory] = [:]
  private static var generation: [UUID: Int] = [:]
  private static var retries: [UUID: Int] = [:]
  private static var pending: Task<Void, Never>?

  static func apply(tab: UUID, url: URL?, loading: Bool) {
    guard let contents = Engine.shared.tabs[tab] else {
      memory[tab] = nil
      generation[tab] = nil
      retries[tab] = nil
      return
    }
    let live = contents.url ?? url
    if StyleSiteSession.shared.isPresented, tab == FrontBrowser.tabID {
      StyleSiteSession.shared.liveURL = live
      if StyleSiteSession.shared.zap != .idle, let live, let styleID = StyleSiteSession.shared.styleID,
        let style = StyleEditing.current().first(where: { $0.id == styleID }),
        ["http", "https"].contains(live.scheme?.lowercased() ?? ""),
        !StyleMatch.matches(live, style, requiringEnabled: false)
      {
        StyleZap.cancel()
      }
    }
    var state = memory[tab] ?? .init()
    let styles = StyleDraft.resolve(StyleEditing.current(), draft: draft)
    guard let plan = StyleApplyPlanner.step(memory: &state, loading: contents.isLoading || loading, url: live, styles: styles) else {
      memory[tab] = state
      return
    }
    memory[tab] = state
    let ticket = (generation[tab] ?? 0) + 1
    generation[tab] = ticket
    let javaScript = StyleMatch.injection(
      css: plan.css, script: plan.runScript ? plan.script : "", scopes: plan.scopes, runScript: plan.runScript)
    contents.evaluateJavaScript(javaScript) { result in
      Task { @MainActor in
        guard StyleEngine.generation[tab] == ticket else { return }
        if result == nil {
          StyleEngine.forgetInstall(tab)
          StyleDiagnostics.shared.message = "Styles could not be injected. The page was not ready."
          return
        }
        if result == "scope" {
          StyleEngine.forgetInstall(tab)
          if let live, Engine.shared.tabs[tab]?.url?.host() == live.host(), !plan.css.isEmpty {
            StyleDiagnostics.shared.message = "Styles did not apply because the page address did not match this site."
            if (StyleEngine.retries[tab] ?? 0) < 2 {
              StyleEngine.retries[tab, default: 0] += 1
              StyleEngine.apply(tab: tab, url: live, loading: false)
            }
          }
          return
        }
        StyleEngine.retries[tab] = 0
        if let result, result.hasPrefix("script:") {
          StyleDiagnostics.shared.message = "Style JavaScript failed: \(result.dropFirst("script:".count))"
        } else if StyleDiagnostics.shared.message != nil {
          StyleDiagnostics.shared.message = nil
        }
      }
    }
  }

  private static func forgetInstall(_ tab: UUID) {
    var state = memory[tab] ?? .init()
    state.css = nil
    state.scriptKey = nil
    memory[tab] = state
  }

  static func applyAll() {
    let live = Set(Engine.shared.tabs.keys)
    for tab in memory.keys where !live.contains(tab) {
      memory[tab] = nil
      generation[tab] = nil
      retries[tab] = nil
    }
    for (tab, contents) in Engine.shared.tabs {
      apply(tab: tab, url: contents.url, loading: contents.isLoading)
    }
  }

  static func applyAllSoon() {
    pending?.cancel()
    pending = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(90))
      guard !Task.isCancelled else { return }
      applyAll()
    }
  }
}
