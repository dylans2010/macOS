import ComposableArchitecture
import Foundation
@preconcurrency import EngineCore

struct PageContext: Equatable, Sendable {
  var tab: Tab.ID
  var url: URL
  var title: String
  var text: String
  var headings: [Heading]
  var description: String?
  var selectedText: String?
  var truncated: Bool

  struct Heading: Equatable, Sendable, Codable {
    var level: Int
    var text: String
    var id: String?
  }

  var isReadable: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func promptBlock() -> String {
    var parts = ["Title: \(title)", "URL: \(url.absoluteString)"]
    if let description, !description.isEmpty { parts.append("Description: \(description)") }
    if !headings.isEmpty {
      parts.append("Headings:")
      parts.append(contentsOf: headings.prefix(40).map { "h\($0.level) \($0.text)" })
    }
    if let selectedText, !selectedText.isEmpty {
      parts.append("Selected text:\n\(selectedText)")
    }
    parts.append("Body:\n\(text)")
    if truncated { parts.append("(The extracted text was truncated.)") }
    return AIGuard.wrapUntrusted(parts.joined(separator: "\n"), label: "webpage")
  }
}

enum PageExtractor {
  static let maxText = 12_000

  static let script = """
    (() => {
      const title = document.title || '';
      const description = document.querySelector('meta[name="description"]')?.content
        || document.querySelector('meta[property="og:description"]')?.content || '';
      const headings = [...document.querySelectorAll('h1,h2,h3,h4')].slice(0, 40).map((node) => ({
        level: Number(node.tagName[1]),
        text: (node.innerText || '').trim().slice(0, 200),
        id: node.id || null
      })).filter((item) => item.text);
      const selected = (window.getSelection && window.getSelection().toString() || '').trim().slice(0, 2000);
      const root = document.querySelector('article, main, [role="main"]') || document.body;
      const clone = root ? root.cloneNode(true) : document.createElement('div');
      for (const node of clone.querySelectorAll('script, style, noscript, input, textarea, select, [hidden], [aria-hidden="true"]')) {
        node.remove();
      }
      let text = (clone.innerText || '').replace(/\\s+/g, ' ').trim();
      const truncated = text.length > \(maxText);
      if (truncated) text = text.slice(0, \(maxText));
      return JSON.stringify({title, description, headings, selected, text, truncated});
    })()
    """

  static func parse(_ json: String, tab: Tab.ID, url: URL, fallbackTitle: String) -> PageContext? {
    struct Payload: Decodable {
      var title: String?
      var description: String?
      var headings: [PageContext.Heading]?
      var selected: String?
      var text: String?
      var truncated: Bool?
    }
    guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else { return nil }
    let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return PageContext(
      tab: tab, url: url, title: (payload.title?.isEmpty == false ? payload.title! : fallbackTitle),
      text: text, headings: payload.headings ?? [],
      description: payload.description.flatMap { $0.isEmpty ? nil : $0 },
      selectedText: payload.selected.flatMap { $0.isEmpty ? nil : $0 },
      truncated: payload.truncated ?? false)
  }
}

@DependencyClient
struct PageContextClient: Sendable {
  var extract: @Sendable (_ tab: Tab.ID, _ url: URL, _ title: String) async -> PageContext?
}

extension PageContextClient: TestDependencyKey {
  static let testValue = Self()
}

extension PageContextClient: DependencyKey {
  static let liveValue = Self { tab, url, title in
    await Engine.shared.extractPageContext(tab: tab, url: url, title: title)
  }
}

extension Engine {
  fileprivate func extractPageContext(tab: Tab.ID, url: URL, title: String) async -> PageContext? {
    guard let contents = tabs[tab] else { return nil }
    let currentURL = contents.url ?? url
    let token = ObjectIdentifier(contents)
    let json = await evaluateJavaScript(PageExtractor.script, in: contents)
    guard tabs[tab].map(ObjectIdentifier.init) == token else { return nil }
    if let json, let context = PageExtractor.parse(json, tab: tab, url: currentURL, fallbackTitle: title) {
      return context
    }
    guard let contents = tabs[tab], ObjectIdentifier(contents) == token else { return nil }
    let articleJSON = await evaluateJavaScript(ReaderScript.article, in: contents)
    guard tabs[tab].map(ObjectIdentifier.init) == token, let articleJSON,
      let article = ReaderScript.article(fromJSON: articleJSON)
    else { return nil }
    let text = HTMLText.strip(article.content)
    return PageContext(
      tab: tab, url: currentURL, title: article.title.isEmpty ? title : article.title,
      text: String(text.prefix(PageExtractor.maxText)), headings: [],
      description: article.byline, selectedText: selections[tab],
      truncated: text.count > PageExtractor.maxText)
  }

  fileprivate func evaluateJavaScript(_ script: String, in contents: ECWebContents) async -> String? {
    await withCheckedContinuation { continuation in
      contents.evaluateJavaScript(script) { json in
        MainActor.assumeIsolated {
          continuation.resume(returning: json)
        }
      }
    }
  }
}

extension DependencyValues {
  var pageContext: PageContextClient {
    get { self[PageContextClient.self] }
    set { self[PageContextClient.self] = newValue }
  }
}
