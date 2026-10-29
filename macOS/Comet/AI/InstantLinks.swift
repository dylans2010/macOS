import Foundation

enum InstantLinks {
  // The first destination a Command Bar query should open: a real URL/history/bookmark match, else DuckDuckGo's
  // Instant Answer, else the ordinary search page. Ads are not treated as organic results.
  static func destination(
    query: String, matches: [AutocompleteMatch], search: (String) -> URL,
    instantAnswer: ((String) async -> URL?)? = nil
  ) async -> URL {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return search(trimmed) }
    if let match = matches.first(where: { $0.type != .search }) {
      return match.url
    }
    if let instant = await (instantAnswer ?? duckDuckGo)(trimmed) { return instant }
    return search(trimmed)
  }

  static func duckDuckGo(_ query: String) async -> URL? {
    var components = URLComponents(string: "https://api.duckduckgo.com/")!
    components.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "no_redirect", value: "1"),
      URLQueryItem(name: "no_html", value: "1"),
    ]
    guard let url = components.url else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 6
    do {
      let (data, response) = try await PageFetch.session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      for key in ["Redirect", "AbstractURL"] {
        if let value = json[key] as? String, let destination = usable(value) { return destination }
      }
      if let results = json["Results"] as? [[String: Any]] {
        for result in results {
          if let destination = usable(result["FirstURL"] as? String) { return destination }
        }
      }
      if let related = json["RelatedTopics"] as? [[String: Any]] {
        for topic in related {
          if let destination = usable(topic["FirstURL"] as? String) { return destination }
          if let topics = topic["Topics"] as? [[String: Any]] {
            for nested in topics {
              if let destination = usable(nested["FirstURL"] as? String) { return destination }
            }
          }
        }
      }
      return nil
    } catch {
      return nil
    }
  }

  private static func usable(_ string: String?) -> URL? {
    guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme), url.host() != nil
    else { return nil }
    return url
  }
}

enum CommandBarAsk {
  static func question(in query: String) -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("?") {
      let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
      return rest.isEmpty ? nil : rest
    }
    if let match = trimmed.prefixMatch(of: /(?i)ask\s+/) {
      let rest = trimmed[match.range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      return rest.isEmpty ? nil : rest
    }
    return nil
  }

  static func request(_ question: String) -> AIRequest {
    AIRequest.make(
      feature: .commandBarAsk,
      system: AIGuard.defaultSystem
        + " Answer the user’s question directly and briefly. If it needs current web results, say so.",
      prompt: question,
      provenance: "command-bar",
      maxTokens: 350,
      timeout: .seconds(30))
  }
}
