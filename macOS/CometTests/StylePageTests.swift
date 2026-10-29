import WebKit
import XCTest

@testable import Comet

// The same DOM script the engine runs, exercised in WebKit's isolated world. Comet's engine runs it with
// ExecuteJavaScriptInIsolatedWorld; these tests check the document result of that script.
@MainActor
final class StylePageTests: XCTestCase {
  private final class LoadWatcher: NSObject, WKNavigationDelegate {
    var loaded: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded?.resume()
      loaded = nil
    }
  }

  private let watcher = LoadWatcher()
  private let html = """
    <!doctype html><html><head><meta charset="utf-8"><style>
      body { margin: 0; background: #ffffff; color: #111111; font-family: Georgia, serif; }
      #fixed { position: fixed; top: 8px; left: 8px; height: 20px; background: #eeeeee; }
      p { font-size: 16px; } code, pre { font-family: Menlo, monospace; }
      #tall { height: 1800px; }
    </style></head><body>
      <header id="fixed">Fixed</header>
      <p id="text">Hello World</p>
      <a id="link" href="https://example.test/x">Link</a>
      <img id="pic" alt="" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">
      <div id="media"><video id="vid"></video></div>
      <code id="code">let value = 1;</code>
      <input id="pw" type="password" value="secret">
      <div id="box" class="ad-slot">Box</div>
      <button id="save">Save</button>
      <div id="tall">Tall</div>
    </body></html>
    """

  private func page(base: String = "https://example.test/article") async throws -> WKWebView {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.navigationDelegate = watcher
    await withCheckedContinuation { continuation in
      watcher.loaded = continuation
      view.loadHTMLString(html, baseURL: URL(string: base))
    }
    return view
  }

  private func run(_ script: String, in page: WKWebView, isolated: Bool = true) async throws -> String? {
    if isolated {
      return try await page.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String
    }
    return try await page.evaluateJavaScript(script) as? String
  }

  private func required(_ value: String?, file: StaticString = #filePath, line: UInt = #line) throws -> String {
    try XCTUnwrap(value, file: file, line: line)
  }

  private func same(_ value: String?, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(value, expected, file: file, line: line)
  }

  private func different(_ value: String?, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotEqual(value, expected, file: file, line: line)
  }

  private func install(_ style: SiteStyle, in page: WKWebView, runScript: Bool = false) async throws -> String? {
    let css = StyleMatch.combinedCSS([style], for: URL(string: "https://example.test/article")!)
    let script = StyleMatch.combinedScript([style], for: URL(string: "https://example.test/article")!)
    let source = StyleMatch.injection(
      css: css, script: runScript ? script : "", scopes: StyleMatch.scopes([style], for: URL(string: "https://example.test/article")!),
      runScript: runScript)
    return try await run(source, in: page)
  }

  func testTheFixturePageHasTheExpectedSite() async throws {
    let view = try await page()
    let location = try await run("location.hostname + location.pathname", in: view)
    XCTAssertEqual(location, "example.test/article")
  }

  func testColorAndThemeChangeTextWithoutRecoloringTheImage() async throws {
    let view = try await page()
    var style = SiteStyle(id: UUID(), name: "Color", hosts: ["example.test"], enabled: true, theme: .light, color: StyleColor(hex: "#2255CC"))
    same(try await install(style, in: view), "ok")
    let colors = try required(try await run(
      """
      const body = getComputedStyle(document.body); const text = getComputedStyle(document.getElementById("text"));
      const link = getComputedStyle(document.getElementById("link")); const image = getComputedStyle(document.getElementById("pic"));
      body.backgroundColor + "|" + text.color + "|" + link.color + "|" + image.filter
      """, in: view))
    let parts = colors.split(separator: "|").map(String.init)
    XCTAssertGreaterThan(parts.count, 3)
    XCTAssertNotEqual(parts[0], "rgb(255, 255, 255)")
    XCTAssertNotEqual(parts[2].lowercased(), parts[1].lowercased())
    XCTAssertTrue(parts[3] == "none" || parts[3].isEmpty)
    style.theme = .dark
    style.color = nil
    same(try await install(style, in: view), "ok")
    let dark = try required(try await run("getComputedStyle(document.body).backgroundColor", in: view))
    XCTAssertNotEqual(dark, "rgb(255, 255, 255)")
    let scheme = try await run("getComputedStyle(document.documentElement).colorScheme", in: view)
    XCTAssertTrue(scheme?.contains("dark") == true, scheme ?? "nil")
  }

  func testAdjustmentsLeavePinnedContentAndMediaAlone() async throws {
    let view = try await page()
    var style = SiteStyle(id: UUID(), name: "Tone", hosts: ["example.test"], enabled: true, contrast: 1.4, brightness: 1, saturation: 1)
    same(try await install(style, in: view), "ok")
    let placed = try required(try await run(
      """
      window.scrollTo(0, 500);
      const fixed = document.getElementById("fixed");
      const text = document.getElementById("text");
      const image = document.getElementById("pic");
      const video = document.getElementById("vid");
      [fixed.getBoundingClientRect().top, fixed.classList.contains("comet-tone"), text.classList.contains("comet-tone"),
        image.classList.contains("comet-tone"), getComputedStyle(video).filter.indexOf("contrast") !== -1].join("|")
      """, in: view))
    let parts = placed.split(separator: "|").map(String.init)
    XCTAssertEqual(parts.count, 5)
    XCTAssertLessThan(Double(parts[0]) ?? 100, 40)
    XCTAssertGreaterThan(Double(parts[0]) ?? -100, -5)
    XCTAssertEqual(parts[1], "true")
    XCTAssertEqual(parts[2], "true")
    XCTAssertEqual(parts[3], "false")
    XCTAssertEqual(parts[4], "true")
    let late = try required(try await run(
      """
      const added = document.createElement("p"); added.id = "late"; added.textContent = "Later";
      document.body.appendChild(added); "added"
      """, in: view))
    XCTAssertEqual(late, "added")
    try await Task.sleep(for: .milliseconds(400))
    let toned = try await run("String(document.getElementById('late').classList.contains('comet-tone'))", in: view)
    XCTAssertEqual(toned, "true")
    let zap = try required(try await run(
      """
      const root = document.createElement("div"); root.id = "comet-zap-root"; document.documentElement.appendChild(root);
      globalThis.__cometApplyTone();
      String(root.classList.contains("comet-tone"))
      """, in: view))
    XCTAssertEqual(zap, "false")
  }

  func testTypographyChangesTextAndLeavesCodeAndPasswords() async throws {
    let view = try await page()
    var style = SiteStyle(
      id: UUID(), name: "Type", hosts: ["example.test"], enabled: true, fontID: "avenir", textScale: 1.4, textCase: .upper)
    same(try await install(style, in: view), "ok")
    let reading = try required(try await run(
      """
      const text = getComputedStyle(document.getElementById("text"));
      const code = getComputedStyle(document.getElementById("code"));
      const password = document.getElementById("pw");
      [text.fontFamily, text.textTransform, text.fontSize, code.fontFamily, code.textTransform,
        document.getElementById("text").textContent, password.value, String((window.visualViewport && window.visualViewport.scale) || 1),
        document.documentElement.style.zoom || ""].join("|")
      """, in: view))
    let parts = reading.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    XCTAssertTrue(parts[0].localizedCaseInsensitiveContains("avenir"))
    XCTAssertEqual(parts[1], "uppercase")
    XCTAssertGreaterThan(Double(parts[2].replacingOccurrences(of: "px", with: "")) ?? 0, 18)
    XCTAssertFalse(parts[3].localizedCaseInsensitiveContains("avenir"))
    XCTAssertEqual(parts[4], "none")
    XCTAssertEqual(parts[5], "Hello World")
    XCTAssertEqual(parts[6], "secret")
    XCTAssertEqual(parts[7], "1")
    XCTAssertEqual(parts[8], "")
  }

  func testZapHidesAStableElementAndNewMatches() async throws {
    let view = try await page()
    let snapshot = try XCTUnwrap(StyleZap.snapshotScript("#save"))
    let json = try required(try await run(snapshot, in: view))
    let chain = try JSONDecoder().decode([StyleNode].self, from: Data(json.utf8))
    let selector = try XCTUnwrap(StyleSelector.candidates(for: chain).first)
    XCTAssertEqual(selector.selector, "#save")
    var style = SiteStyle(id: UUID(), name: "Hide", hosts: ["example.test"], enabled: true)
    style.hidden = [StyleHidden(id: UUID(), selector: ".ad-slot", label: "Box", confidence: .medium)]
    same(try await install(style, in: view), "ok")
    same(try await run("getComputedStyle(document.getElementById('box')).display", in: view), "none")
    same(
      try await run(
        """
        const again = document.createElement("div"); again.className = "ad-slot"; again.id = "again";
        document.body.appendChild(again); getComputedStyle(again).display
        """, in: view), "none")
    style.hidden = []
    same(try await install(style, in: view), "ok")
    different(try await run("getComputedStyle(document.getElementById('box')).display", in: view), "none")
  }

  func testCustomCSSAppliesAndASecondInstallDoesNotDuplicateIt() async throws {
    let view = try await page()
    let style = SiteStyle(id: UUID(), name: "CSS", hosts: ["example.test"], css: "#text { letter-spacing: 2px !important; }", enabled: true)
    same(try await install(style, in: view), "ok")
    same(try await install(style, in: view), "ok")
    same(try await run("String(document.querySelectorAll('#comet-styles').length)", in: view), "1")
    let spacing = try await run("getComputedStyle(document.getElementById('text')).letterSpacing", in: view)
    XCTAssertEqual(spacing, "2px")
    XCTAssertFalse(CSSValidation.issues(in: "#text { letter-spacing: 2px").isEmpty)
  }

  func testJavaScriptIsIsolatedScopedAndCleansUp() async throws {
    let view = try await page()
    _ = try await run("window.__pageSecret = 'nope'", in: view, isolated: false)
    var style = SiteStyle(id: UUID(), name: "JS", hosts: ["example.com"], script: "document.getElementById('text').textContent = 'ran'", scriptEnabled: true, enabled: true)
    let refused = StyleMatch.injection(
      css: "", script: style.script, scopes: [StyleScope(hosts: style.hosts, excludedPaths: [])], runScript: true)
    same(try await run(refused, in: view), "scope")
    same(try await run("document.getElementById('text').textContent", in: view), "Hello World")
    style.hosts = ["example.test"]
    style.script = "document.getElementById('text').textContent = Object.keys(comet).sort().join(',') + ':' + typeof window.__pageSecret"
    same(try await install(style, in: view, runScript: true), "ok")
    same(try await run("document.getElementById('text').textContent", in: view), "onCleanup:undefined")
    style.script = "\");document.getElementById('text').textContent='hacked'"
    let broken = try await install(style, in: view, runScript: true)
    XCTAssertTrue(broken?.hasPrefix("script:") == true)
    different(try await run("document.getElementById('text').textContent", in: view), "hacked")
    style.script = "throw new Error('boom')"
    same(try await install(style, in: view, runScript: true), "script:boom")
    style.script = "function ("
    let syntax = try required(try await install(style, in: view, runScript: true))
    XCTAssertTrue(syntax.hasPrefix("script:"))
    style.script = "setInterval(() => { const n = Number(document.body.dataset.ticks || '0'); document.body.dataset.ticks = String(n + 1); }, 30)"
    same(try await install(style, in: view, runScript: true), "ok")
    try await Task.sleep(for: .milliseconds(120))
    let before = Int(try required(try await run("document.body.dataset.ticks || '0'", in: view))) ?? 0
    XCTAssertGreaterThan(before, 1)
    style.script = ""
    style.scriptEnabled = false
    same(try await install(style, in: view, runScript: true), "ok")
    let stopped = Int(try required(try await run("document.body.dataset.ticks || '0'", in: view))) ?? 0
    try await Task.sleep(for: .milliseconds(150))
    let after = Int(try required(try await run("document.body.dataset.ticks || '0'", in: view))) ?? 0
    XCTAssertLessThanOrEqual(after, stopped + 1)
  }

  func testZapSelectionInstallsAndCanBeCancelled() async throws {
    let view = try await page()
    let style = SiteStyle(id: UUID(), name: "Zap", hosts: ["example.test"], enabled: true)
    let install = StyleZap.installScript(scopes: [StyleScope(hosts: style.hosts, excludedPaths: [])])
    same(try await run(install, in: view), "ok")
    let polling = try await run(StyleZap.pollScript, in: view)
    XCTAssertTrue(polling?.contains("\"active\":true") == true, polling ?? "nil")
    same(try await run(StyleZap.stopScript, in: view), "ok")
    same(try await run("document.getElementById('comet-zap-root') ? 'yes' : 'no'", in: view), "no")
  }

  func testAnExcludedPathDoesNotReceiveTheStyle() async throws {
    let view = try await page(base: "https://example.test/private/x")
    let style = SiteStyle(
      id: UUID(), name: "Private", hosts: ["example.test"], excludedPaths: ["/private"], css: "#text{color:red}", enabled: true)
    let css = StyleMatch.combinedCSS([style], for: URL(string: "https://example.test/private/x")!)
    XCTAssertTrue(css.isEmpty)
    let source = StyleMatch.injection(
      css: "#text{color:red !important}", script: "document.body.dataset.ran='1'",
      scopes: [StyleScope(hosts: style.hosts, excludedPaths: style.excludedPaths)], runScript: true)
    same(try await run(source, in: view), "scope")
    different(try await run("document.body.dataset.ran || ''", in: view), "1")
  }
}
