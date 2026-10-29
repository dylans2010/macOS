import Foundation

enum TidyTitles {
  static let maxLength = 28

  // A short label from a page title and host, without a provider. Site suffixes come off; a still-long remainder
  // is clipped at a word. Nil when the title is already short enough.
  static func shorten(_ title: String, host: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var text = trimmed
    let separators = [" - ", " | ", " · ", " — ", " – ", " • ", " —"]
    for separator in separators {
      if let range = text.range(of: separator, options: .backwards) {
        let suffix = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if suffix.count <= 24 { text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }
        break
      }
    }
    if text.count <= maxLength { return text == trimmed ? nil : text }
    let clipped = clip(text, to: maxLength)
    return clipped == trimmed ? nil : clipped
  }

  static func clip(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    let prefix = String(text.prefix(limit))
    if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) >= 10 {
      return String(prefix[..<space])
    }
    return prefix.trimmingCharacters(in: .whitespaces)
  }

  static func needsModel(_ title: String, host: String) -> Bool {
    guard let short = shorten(title, host: host) else { return false }
    // A remaining headline that still looks like a sentence benefits from a semantic short name.
    return short.split(whereSeparator: \.isWhitespace).count >= 5
  }

  static func request(title: String, host: String) -> AIRequest {
    AIRequest.make(
      feature: .tidyTabTitles,
      system: AIGuard.defaultSystem + """
         Return only a short pinned-tab label, at most \(maxLength) characters, based on the given title and site. \
        Do not invent a product or name that is not in the title. No quotes or trailing site suffix.
        """,
      prompt: "Title: \(title)\nSite: \(host)",
      provenance: "title:\(host)",
      cacheKey: "title:\(host)|\(title)",
      maxTokens: 24,
      timeout: .seconds(12))
  }

  static func sanitize(_ proposed: String, original: String, host: String) -> String? {
    var text = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 1 {
      text = String(text.dropFirst().dropLast())
    }
    text = clip(text, to: maxLength)
    guard !text.isEmpty, text.lowercased() != original.lowercased() else { return shorten(original, host: host) }
    return text
  }
}
