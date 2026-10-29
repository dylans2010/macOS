import Foundation

struct FetchedPage: Equatable, Sendable {
  var url: URL
  var title: String
  var description: String?
  var text: String
  var retrieved: Bool
}

enum HTMLText {
  static let maxBytes = 512_000
  static let maxText = 6_000

  static func parse(_ html: String, url: URL) -> FetchedPage {
    let title = first(html, #"<title[^>]*>(.*?)</title>"#) ?? url.host() ?? url.absoluteString
    let description =
      namedMeta(html, "description") ?? namedMeta(html, "og:description") ?? propertyMeta(html, "og:description")
    let stripped = strip(html)
    return FetchedPage(
      url: url, title: decode(title).trimmingCharacters(in: .whitespacesAndNewlines),
      description: description.map { decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap {
        $0.isEmpty ? nil : $0
      }, text: String(stripped.prefix(maxText)), retrieved: true)
  }

  static func strip(_ html: String) -> String {
    var text = html
    for pattern in [#"<script\b[\s\S]*?</script>"#, #"<style\b[\s\S]*?</style>"#, #"<noscript\b[\s\S]*?</noscript>"#, #"<!--[\s\S]*?-->"#] {
      text = text.replacing(try! Regex(pattern).ignoresCase(), with: " ")
    }
    text = text.replacing(#/<[^>]+>/#, with: " ")
    text = decode(text)
    let collapsed = text.replacing(#/[ \t\f\r]+/#, with: " ").replacing(#/\n{3,}/#, with: "\n\n")
    return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func namedMeta(_ html: String, _ name: String) -> String? {
    first(html, #"<meta[^>]+name=["']\#(name)["'][^>]+content=["']([^"']+)["']"#)
      ?? first(html, #"<meta[^>]+content=["']([^"']+)["'][^>]+name=["']\#(name)["']"#)
  }

  private static func propertyMeta(_ html: String, _ property: String) -> String? {
    first(html, #"<meta[^>]+property=["']\#(property)["'][^>]+content=["']([^"']+)["']"#)
  }

  private static func first(_ html: String, _ pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
      match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: html)
    else { return nil }
    return String(html[range])
  }

  static func decode(_ text: String) -> String {
    var result = text
    for (entity, replacement) in [
      ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
    ] {
      result = result.replacingOccurrences(of: entity, with: replacement)
    }
    result = result.replacing(#/&#(\d+);/#) { match in
      guard let value = Int(match.1), let scalar = UnicodeScalar(value) else { return String(match.0) }
      return String(Character(scalar))
    }
    return result
  }
}

enum PageFetch {
  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.httpAdditionalHeaders = [
      "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
      "User-Agent": "Comet/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1") (Link Preview)",
    ]
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  static func isPreviewable(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else {
      return false
    }
    return true
  }

  static func fetch(_ url: URL) async throws -> FetchedPage {
    guard isPreviewable(url) else { throw AIFailure.network("That destination cannot be previewed.") }
    if await Robots.disallows(url) {
      throw AIFailure.network("This site does not allow automated previews.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AIFailure.network("The destination returned no response.") }
    guard (200..<400).contains(http.statusCode) else {
      throw AIFailure.http(http.statusCode, "The destination could not be read.")
    }
    let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    guard type.isEmpty || type.contains("html") || type.contains("xml") || type.contains("text/plain") else {
      throw AIFailure.network("The destination is not a webpage.")
    }
    let html = String(data: Data(data.prefix(HTMLText.maxBytes)), encoding: .utf8)
      ?? String(decoding: data.prefix(HTMLText.maxBytes), as: UTF8.self)
    var page = HTMLText.parse(html, url: (http.url ?? url))
    if page.title.isEmpty { page.title = url.host() ?? url.absoluteString }
    return page
  }
}

actor Robots {
  static let shared = Robots()
  private var cache: [String: (allowed: Bool, at: Date)] = [:]
  private let ttl: TimeInterval = 3_600

  static func disallows(_ url: URL) async -> Bool {
    await shared.disallows(url)
  }

  func disallows(_ url: URL) async -> Bool {
    guard let origin = url.origin else { return false }
    if let cached = cache[origin], Date().timeIntervalSince(cached.at) < ttl { return !cached.allowed }
    guard let robotsURL = URL(string: origin + "/robots.txt") else { return false }
    do {
      var request = URLRequest(url: robotsURL)
      request.timeoutInterval = 3
      let (data, response) = try await PageFetch.session.data(for: request)
      let allowed: Bool
      if let http = response as? HTTPURLResponse, http.statusCode == 200,
        let text = String(data: data, encoding: .utf8)
      {
        allowed = allows(text, path: url.path())
      } else {
        allowed = true
      }
      cache[origin] = (allowed, Date())
      return !allowed
    } catch {
      cache[origin] = (true, Date())
      return false
    }
  }

  // A conservative read of User-agent: * Disallow rules. Allow: / wins over a matching Disallow of equal length.
  func allows(_ robots: String, path: String) -> Bool {
    let path = path.isEmpty ? "/" : path
    var inStar = false
    var disallows: [String] = []
    var allows: [String] = []
    for raw in robots.split(whereSeparator: \.isNewline) {
      let line = raw.split(separator: "#", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      if line.lowercased().hasPrefix("user-agent:") {
        let agent = String(line.dropFirst("user-agent:".count)).trimmingCharacters(in: .whitespaces).lowercased()
        inStar = agent == "*"
        continue
      }
      guard inStar else { continue }
      if line.lowercased().hasPrefix("disallow:") {
        disallows.append(String(line.dropFirst("disallow:".count)).trimmingCharacters(in: .whitespaces))
      } else if line.lowercased().hasPrefix("allow:") {
        allows.append(String(line.dropFirst("allow:".count)).trimmingCharacters(in: .whitespaces))
      }
    }
    let disallow = disallows.filter { !$0.isEmpty && path.hasPrefix($0) }.max(by: { $0.count < $1.count })
    let allow = allows.filter { path.hasPrefix($0) }.max(by: { $0.count < $1.count })
    if let disallow {
      return (allow?.count ?? 0) >= disallow.count
    }
    return true
  }
}

extension URL {
  var origin: String? {
    guard let scheme, let host = host() else { return nil }
    return port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
  }
}
