import AppKit
import Foundation
import SwiftUI

// Visual controls compiled into the site stylesheet. The page's own CSS variables are not assumed:
// a palette paints the document background, common text, and links, and an optional compatibility pass
// paints nested boxes. Images and video are not recolored. Adjustments use a filter on content boxes
// that do not wrap a pinned element, so position:fixed keeps the viewport as its containing block.

enum StyleTheme: String, Codable, CaseIterable, Identifiable, Sendable {
  case website, light, dark
  var id: String { rawValue }
  var title: String {
    switch self {
    case .website: "Site"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
  var symbol: String {
    switch self {
    case .website: "lightbulb"
    case .light: "sun.max.fill"
    case .dark: "moon.fill"
    }
  }
}

enum StyleTextCase: String, Codable, CaseIterable, Identifiable, Sendable {
  case original, lower, upper, capitalized
  var id: String { rawValue }
  var sample: String {
    switch self {
    case .original: "Aa"
    case .lower: "aa"
    case .upper: "AA"
    case .capitalized: "aA"
    }
  }
  var title: String {
    switch self {
    case .original: "Original capitalization"
    case .lower: "Lowercase"
    case .upper: "Uppercase"
    case .capitalized: "Capitalize words"
    }
  }
  var css: String? {
    switch self {
    case .original: nil
    case .lower: "lowercase"
    case .upper: "uppercase"
    case .capitalized: "capitalize"
    }
  }
}

enum StyleConfidence: String, Codable, Sendable {
  case high, medium, low
  var title: String {
    switch self {
    case .high: "Stable"
    case .medium: "Likely"
    case .low: "Positional"
    }
  }
}

enum StyleLimits {
  static func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
  static func contrast(_ value: Double) -> Double { min(max(value, 0.5), 1.8) }
  static func brightness(_ value: Double) -> Double { min(max(value, 0.5), 1.6) }
  static func saturation(_ value: Double) -> Double { min(max(value, 0), 2) }
  static func scale(_ value: Double) -> Double { min(max(value, 0.75), 1.75) }
  static func near(_ value: Double, _ target: Double, tolerance: Double = 0.001) -> Bool {
    abs(value - target) < tolerance
  }
  static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
  static func number(_ value: Double) -> String {
    var text = String(format: "%.4f", value)
    while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") { text.removeLast() }
    return text.isEmpty ? "0" : text
  }
}

struct StyleRGB: Equatable, Sendable {
  var red: Double
  var green: Double
  var blue: Double

  init(red: Double, green: Double, blue: Double) {
    self.red = min(max(red, 0), 1)
    self.green = min(max(green, 0), 1)
    self.blue = min(max(blue, 0), 1)
  }

  init(white: Double) { self.init(red: white, green: white, blue: white) }

  init(hue: Double, saturation: Double, brightness: Double) {
    let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(.deviceRGB)
    self.init(
      red: Double(color?.redComponent ?? 0), green: Double(color?.greenComponent ?? 0), blue: Double(color?.blueComponent ?? 0))
  }

  var hex: String {
    String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
  }

  var luminance: Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  static func contrast(_ a: StyleRGB, _ b: StyleRGB) -> Double {
    let lighter = max(a.luminance, b.luminance)
    let darker = min(a.luminance, b.luminance)
    return (lighter + 0.05) / (darker + 0.05)
  }

  private func channel(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
}

struct StyleColor: Codable, Equatable, Sendable {
  var hue: Double
  var saturation: Double
  var brightness: Double

  init(hue: Double, saturation: Double, brightness: Double) {
    self.hue = StyleLimits.unit(hue)
    self.saturation = StyleLimits.unit(saturation)
    self.brightness = StyleLimits.unit(brightness)
  }

  init?(hex: String) {
    var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 3 || text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
    if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
    guard let value = UInt32(text, radix: 16) else { return nil }
    let color = NSColor(
      srgbRed: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255, alpha: 1
    ).usingColorSpace(.deviceRGB)
    guard let color else { return nil }
    self.init(
      hue: Double(color.hueComponent), saturation: Double(color.saturationComponent), brightness: Double(color.brightnessComponent))
  }

  var rgb: StyleRGB { StyleRGB(hue: hue, saturation: saturation, brightness: brightness) }
}

struct StyleHidden: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var selector: String
  var label: String
  var confidence: StyleConfidence
}

struct StyleFont: Identifiable, Equatable, Sendable {
  var id: String
  var name: String
  var family: String
  var stack: String
  var system: Bool = false

  var sample: Font {
    system ? .system(size: 22, weight: .medium) : .custom(family, size: 22)
  }
}

enum StyleFonts {
  static let catalog: [StyleFont] = [
    StyleFont(id: "system", name: "System", family: "System", stack: "-apple-system, BlinkMacSystemFont, sans-serif", system: true),
    StyleFont(id: "avenir", name: "Avenir", family: "Avenir Next", stack: "\"Avenir Next\", Avenir, sans-serif"),
    StyleFont(id: "helvetica", name: "Helvetica", family: "Helvetica Neue", stack: "\"Helvetica Neue\", Helvetica, sans-serif"),
    StyleFont(id: "gill", name: "Gill Sans", family: "Gill Sans", stack: "\"Gill Sans\", \"Gill Sans MT\", sans-serif"),
    StyleFont(id: "futura", name: "Futura", family: "Futura", stack: "Futura, \"Trebuchet MS\", sans-serif"),
    StyleFont(id: "georgia", name: "Georgia", family: "Georgia", stack: "Georgia, serif"),
    StyleFont(id: "charter", name: "Charter", family: "Charter", stack: "Charter, Georgia, serif"),
    StyleFont(id: "baskerville", name: "Baskerville", family: "Baskerville", stack: "Baskerville, \"Times New Roman\", serif"),
    StyleFont(id: "palatino", name: "Palatino", family: "Palatino", stack: "Palatino, \"Palatino Linotype\", serif"),
    StyleFont(id: "menlo", name: "Menlo", family: "Menlo", stack: "Menlo, ui-monospace, monospace"),
  ]

  static var available: [StyleFont] {
    catalog.filter { font in
      font.system || NSFontManager.shared.availableMembers(ofFontFamily: font.family) != nil
    }
  }

  static func named(_ id: String?) -> StyleFont? {
    guard let id else { return nil }
    return catalog.first { $0.id == id }
  }
}

struct StyleScope: Equatable, Sendable {
  var hosts: [String]
  var excludedPaths: [String]
}

enum StyleScopeRules {
  static func problem(_ rule: String) -> String? {
    let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
    if rule.isEmpty { return nil }
    if rule == "*" || rule == "*://*" { return "A style cannot match every site." }
    if rule.contains("://") {
      guard rule.range(of: "://") != nil, !rule.hasPrefix("://") else { return "That address is incomplete." }
      return nil
    }
    if rule.contains("/") { return "Use a full address, such as https://example.com/docs*, to match a path." }
    if rule.contains("*"), !rule.hasPrefix("*.") || String(rule.dropFirst(2)).contains("*") {
      return "The only wildcard is *.example.com."
    }
    if rule.hasPrefix("*.") && String(rule.dropFirst(2)).isEmpty { return "Name the site after *." }
    return nil
  }
}

enum StylePalette {
  struct Paint: Equatable {
    var scheme: String
    var background: StyleRGB
    var surface: StyleRGB
    var text: StyleRGB
    var muted: StyleRGB
    var accent: StyleRGB
    var link: StyleRGB
    var border: StyleRGB
    var onAccent: StyleRGB
  }

  static func paint(theme: StyleTheme, color: StyleColor?) -> Paint? {
    switch theme {
    case .website:
      guard let color else { return nil }
      return make(scheme: "light", hue: color.hue, saturation: color.saturation, accent: color.rgb)
    case .light:
      let accent = color?.rgb ?? StyleRGB(hue: 0.58, saturation: 0.72, brightness: 0.72)
      return make(scheme: "light", hue: color?.hue ?? 0.6, saturation: color?.saturation ?? 0.08, accent: accent)
    case .dark:
      let accent = color?.rgb ?? StyleRGB(hue: 0.6, saturation: 0.45, brightness: 1)
      return make(scheme: "dark", hue: color?.hue ?? 0.62, saturation: max(color?.saturation ?? 0.2, 0.12), accent: accent)
    }
  }

  private static func make(scheme: String, hue: Double, saturation: Double, accent: StyleRGB) -> Paint {
    let dark = scheme == "dark"
    let background = StyleRGB(
      hue: hue, saturation: min(saturation * (dark ? 0.45 : 0.16), dark ? 0.42 : 0.22), brightness: dark ? 0.12 : 0.98)
    let surface = StyleRGB(
      hue: hue, saturation: min(saturation * (dark ? 0.38 : 0.12), dark ? 0.34 : 0.18), brightness: dark ? 0.17 : 0.95)
    var text = StyleRGB(hue: hue, saturation: dark ? 0.04 : min(0.22, saturation * 0.3 + 0.04), brightness: dark ? 0.96 : 0.13)
    if StyleRGB.contrast(text, background) < 4.5 {
      text = StyleRGB(white: dark ? 0.96 : 0.08)
    }
    let muted = StyleRGB(hue: hue, saturation: 0.08, brightness: dark ? 0.72 : 0.38)
    let border = StyleRGB(hue: hue, saturation: min(max(saturation, 0.04) * 0.25, 0.3), brightness: dark ? 0.28 : 0.84)
    var link = readable(accent, on: background, hue: hue, dark: dark)
    if StyleRGB.contrast(link, text) < 1.25 {
      link = readable(
        StyleRGB(hue: hue + 0.08, saturation: min(1, saturation + 0.25), brightness: dark ? 0.9 : 0.42),
        on: background, hue: hue + 0.08, dark: dark)
    }
    let onAccent = accent.luminance > 0.45 ? StyleRGB(white: 0.08) : StyleRGB(white: 0.98)
    return Paint(
      scheme: scheme, background: background, surface: surface, text: text, muted: muted, accent: accent, link: link,
      border: border, onAccent: onAccent)
  }

  private static func readable(_ accent: StyleRGB, on background: StyleRGB, hue: Double, dark: Bool) -> StyleRGB {
    if StyleRGB.contrast(accent, background) >= 4.5 { return accent }
    let towardDark = background.luminance > 0.5
    var brightness = towardDark ? min(accent.luminance + 0.05, 0.55) : max(accent.luminance, 0.55)
    var color = accent
    for _ in 0..<14 {
      brightness = towardDark ? max(0.12, brightness - 0.05) : min(1, brightness + 0.05)
      color = StyleRGB(hue: hue, saturation: min(1, 0.55), brightness: brightness)
      if StyleRGB.contrast(color, background) >= 4.5 { return color }
    }
    return StyleRGB(white: dark || !towardDark ? 0.96 : 0.1)
  }
}

enum StyleVisuals {
  static func appliedCSS(_ style: SiteStyle) -> String {
    var parts: [String] = []
    if style.visualsEnabled, let visual = visualCSS(style), !visual.isEmpty { parts.append(visual) }
    let hidden = hiddenCSS(style.hidden)
    if !hidden.isEmpty { parts.append(hidden) }
    let custom = style.css.trimmingCharacters(in: .whitespacesAndNewlines)
    if !custom.isEmpty { parts.append(custom) }
    return parts.joined(separator: "\n")
  }

  static func visualCSS(_ style: SiteStyle) -> String? {
    var parts: [String] = []
    if let palette = paletteCSS(style) { parts.append(palette) }
    if let tone = toneCSS(style) { parts.append(tone) }
    if let font = fontCSS(style.fontID) { parts.append(font) }
    if let size = sizeCSS(style.textScale) { parts.append(size) }
    if let textCase = caseCSS(style.textCase) { parts.append(textCase) }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  static func paletteCSS(_ style: SiteStyle) -> String? {
    guard let paint = StylePalette.paint(theme: style.theme, color: style.color) else { return nil }
    let background = paint.background.hex
    let surface = paint.surface.hex
    let text = paint.text.hex
    let muted = paint.muted.hex
    let accent = paint.accent.hex
    let link = paint.link.hex
    let border = paint.border.hex
    let onAccent = paint.onAccent.hex
    var css = """
      /* comet-palette: page background, text, and links. Nested boxes keep their colors unless Boxes is on. */
      html {
        color-scheme: \(paint.scheme) !important;
        background-color: \(background) !important;
        --comet-bg: \(background);
        --comet-surface: \(surface);
        --comet-fg: \(text);
        --comet-muted: \(muted);
        --comet-accent: \(accent);
        --comet-link: \(link);
        --comet-border: \(border);
        --comet-on-accent: \(onAccent);
        --background: \(background) !important;
        --bg: \(background) !important;
        --color-bg: \(background) !important;
        --color-background: \(background) !important;
        --foreground: \(text) !important;
        --text: \(text) !important;
        --color-text: \(text) !important;
        --color-foreground: \(text) !important;
        --primary: \(accent) !important;
        --accent: \(accent) !important;
        --color-primary: \(accent) !important;
        --theme-color: \(accent) !important;
        --link: \(link) !important;
        --link-color: \(link) !important;
      }
      body { background-color: var(--comet-bg) !important; color: var(--comet-fg) !important; }
      body :where(article, main, header, footer, nav, aside) {
        background-color: var(--comet-surface) !important; color: var(--comet-fg) !important;
      }
      body :where(p, li, h1, h2, h3, h4, h5, h6, td, th, dd, dt, figcaption, blockquote, label) {
        color: var(--comet-fg) !important;
      }
      a, a:visited { color: var(--comet-link) !important; }
      ::selection { background-color: var(--comet-accent); color: var(--comet-on-accent); }
      img, video, canvas, svg, picture, iframe, embed, object { background-color: transparent !important; }
      """
    if style.recolorBoxes {
      css += """

        /* comet-boxes */
        body :where(div, span, ul, ol, form, table, figure, dialog, section) {
          background-color: var(--comet-bg) !important;
          color: var(--comet-fg) !important;
          border-color: var(--comet-border) !important;
        }
        """
    }
    return css
  }

  static func toneCSS(_ style: SiteStyle) -> String? {
    guard style.hasAdjustments else { return nil }
    let contrast = StyleLimits.contrast(style.contrast)
    let brightness = StyleLimits.brightness(style.brightness)
    let saturation = StyleLimits.saturation(style.saturation)
    let inverse = "saturate(\(StyleLimits.number(inverseFactor(saturation)))) brightness(\(StyleLimits.number(inverseFactor(brightness)))) contrast(\(StyleLimits.number(inverseFactor(contrast))))"
    return """
      /* comet-tone */
      .comet-tone { filter: contrast(\(StyleLimits.number(contrast))) brightness(\(StyleLimits.number(brightness))) saturate(\(StyleLimits.number(saturation))) !important; }
      .comet-tone :is(img, video, canvas, svg, picture, iframe, embed, object) { filter: \(inverse) !important; }
      #comet-zap-root, #comet-zap-root * { filter: none !important; }
      """
  }

  static func fontCSS(_ id: String?) -> String? {
    guard let font = StyleFonts.named(id) else { return nil }
    return """
      /* comet-font */
      body :where(p, li, a, h1, h2, h3, h4, h5, h6, button, input, textarea, select, label, td, th, dd, dt, figcaption, blockquote, summary, legend, nav, header, footer, article, section, span, div) {
        font-family: \(font.stack) !important;
      }
      code, pre, kbd, samp, var, tt, input[type="password"],
      .material-icons, .material-symbols-outlined, .material-symbols-rounded, .material-symbols-sharp,
      .fa, .fas, .far, .fab, .fal, .bi, .octicon, .codicon, .glyphicon, .dashicons,
      .monaco-editor, .monaco-editor *, .cm-editor, .cm-editor *, .ace_editor, .ace_editor * {
        font-family: revert !important;
      }
      """
  }

  static func sizeCSS(_ scale: Double) -> String? {
    let scale = StyleLimits.scale(scale)
    guard !StyleLimits.near(scale, 1) else { return nil }
    let number = StyleLimits.number(scale)
    return """
      /* comet-size */
      html { font-size: calc(100% * \(number)) !important; }
      body :where(p, li, td, th, dd, dt, figcaption, blockquote, label, a, button, input, textarea, select) { font-size: 1rem !important; }
      body :where(h1) { font-size: 2.15rem !important; }
      body :where(h2) { font-size: 1.7rem !important; }
      body :where(h3) { font-size: 1.4rem !important; }
      body :where(h4) { font-size: 1.2rem !important; }
      body :where(h5, h6) { font-size: 1.05rem !important; }
      code, pre, kbd, samp, input[type="password"], .monaco-editor, .monaco-editor *, .cm-editor, .cm-editor * { font-size: revert !important; }
      """
  }

  static func caseCSS(_ textCase: StyleTextCase) -> String? {
    guard let value = textCase.css else { return nil }
    return """
      /* comet-case */
      body :where(p, li, h1, h2, h3, h4, h5, h6, a, button, label, td, th, figcaption, blockquote, nav, summary) {
        text-transform: \(value) !important;
      }
      code, pre, kbd, samp, input, textarea, select, [contenteditable="true"],
      .material-icons, .material-symbols-outlined, .fa, .fas, .far, .fab, .bi, .octicon, .codicon,
      .monaco-editor, .monaco-editor *, .cm-editor, .cm-editor * { text-transform: none !important; }
      """
  }

  static func hiddenCSS(_ rules: [StyleHidden]) -> String {
    let lines = rules.compactMap { rule -> String? in
      guard StyleSelector.isSafe(rule.selector) else { return nil }
      return "\(rule.selector) { display: none !important; }"
    }
    guard !lines.isEmpty else { return "" }
    return "/* comet-hidden */\n" + lines.joined(separator: "\n")
  }

  private static func inverseFactor(_ value: Double) -> Double {
    abs(value) < 0.001 ? 0 : 1 / value
  }
}

struct StyleNode: Codable, Equatable, Sendable {
  var tag: String
  var id: String
  var idCount: Int
  var classes: [String]
  var classCount: [String: Int]
  var attributes: [String: String]
  var attributeCount: [String: Int]
  var nth: Int
  var siblings: Int
  var text: String
}

enum StyleSelector {
  struct Candidate: Equatable, Identifiable, Sendable {
    var selector: String
    var label: String
    var confidence: StyleConfidence
    var id: String { selector }
  }

  static func candidates(for chain: [StyleNode]) -> [Candidate] {
    guard let element = chain.first else { return [] }
    var results: [Candidate] = []
    if let best = specific(element) { results.append(best) }
    let path = positional(chain)
    if isSafe(path), results.first?.selector != path {
      results.append(
        Candidate(
          selector: path, label: element.text.isEmpty ? element.tag : element.text,
          confidence: path.contains("nth-of-type") ? .low : .medium))
    }
    for node in chain.dropFirst() {
      guard let best = specific(node), !results.contains(where: { $0.selector == best.selector }) else { continue }
      results.append(Candidate(selector: best.selector, label: "Broader · \(best.label)", confidence: best.confidence))
    }
    return results
  }

  static func isSafe(_ selector: String) -> Bool {
    let text = selector.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...300).contains(text.count) else { return false }
    let lowered = text.lowercased()
    if ["html", "body", "head", ":root", "*"].contains(lowered) { return false }
    if lowered.contains("comet-") || lowered.contains("javascript") || lowered.contains("expression") || lowered.contains("url(")
      || lowered.contains("@")
    {
      return false
    }
    if text.contains("{") || text.contains("}") || text.contains(";") || text.contains("\\") || text.contains("<") { return false }
    guard text.contains(where: \.isLetter) || text.contains("#") else { return false }
    let punctuation = CharacterSet(charactersIn: "#.:-_=[] >()'\"")
    var quote: Unicode.Scalar?
    for scalar in text.unicodeScalars {
      if scalar == "\"" || scalar == "'" {
        if quote == scalar { quote = nil } else if quote == nil { quote = scalar }
        continue
      }
      if quote != nil { continue }
      if CharacterSet.alphanumerics.contains(scalar) || punctuation.contains(scalar) { continue }
      return false
    }
    return quote == nil
  }

  static func isIdent(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-" || $0 == "_"
    }
  }

  private static let attributes = ["data-testid", "data-test", "data-cy", "data-id", "name", "aria-label", "role"]

  private static func specific(_ node: StyleNode) -> Candidate? {
    if isIdent(node.id), node.idCount == 1 {
      let selector = "#\(node.id)"
      if isSafe(selector) { return Candidate(selector: selector, label: node.id, confidence: .high) }
    }
    for key in attributes {
      guard let value = node.attributes[key], let quoted = quote(value), node.attributeCount["\(key)=\(value)"] == 1 else { continue }
      let selector = "\(node.tag)[\(key)=\(quoted)]"
      if isSafe(selector) { return Candidate(selector: selector, label: value, confidence: .high) }
    }
    for name in node.classes where isIdent(name) && node.classCount[name] == 1 {
      let selector = "\(node.tag).\(name)"
      if isSafe(selector) { return Candidate(selector: selector, label: name, confidence: .medium) }
    }
    return nil
  }

  private static func positional(_ chain: [StyleNode]) -> String {
    let nodes = Array(chain.reversed())
    guard !nodes.isEmpty else { return "" }
    var parts: [String] = []
    var start = 0
    if let index = nodes.indices.last(where: { isIdent(nodes[$0].id) && nodes[$0].idCount == 1 }) {
      parts.append("#\(nodes[index].id)")
      start = index + 1
    }
    guard start < nodes.count else { return parts.joined(separator: " > ") }
    for node in nodes[start...] {
      guard node.tag.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
      if node.siblings > 1, node.nth > 0 {
        parts.append("\(node.tag):nth-of-type(\(node.nth))")
      } else {
        parts.append(node.tag)
      }
    }
    return parts.joined(separator: " > ")
  }

  private static func quote(_ value: String) -> String? {
    guard (1..<80).contains(value.count) else { return nil }
    let extra = CharacterSet(charactersIn: "-_ .:")
    guard value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || extra.contains($0) }) else { return nil }
    return "\"\(value)\""
  }
}

enum StylePanelLayout {
  static func styleOrigin(offset: CGSize, panel: CGSize, bounds: CGSize, moved: Bool) -> CGPoint {
    let anchor = CGPoint(x: bounds.width - panel.width - 16, y: 16)
    return clamp(anchor: anchor, offset: moved ? offset : .zero, panel: panel, bounds: bounds)
  }

  static func codeOrigin(offset: CGSize, panel: CGSize, bounds: CGSize, styleFrame: CGRect, moved: Bool) -> CGPoint {
    var anchor = CGPoint(x: 16, y: 16)
    if !moved {
      let proposed = CGRect(origin: anchor, size: panel)
      if proposed.intersects(styleFrame.insetBy(dx: -8, dy: -8)) {
        anchor.y = min(styleFrame.maxY + 12, max(16, bounds.height - panel.height - 16))
      }
    }
    return clamp(anchor: anchor, offset: moved ? offset : .zero, panel: panel, bounds: bounds)
  }

  static func clamp(anchor: CGPoint, offset: CGSize, panel: CGSize, bounds: CGSize) -> CGPoint {
    let raw = CGPoint(x: anchor.x + offset.width, y: anchor.y + offset.height)
    let maxX = max(8, bounds.width - panel.width - 8)
    let maxY = max(8, bounds.height - panel.height - 8)
    return CGPoint(x: min(max(8, raw.x), maxX), y: min(max(8, raw.y), maxY))
  }
}
