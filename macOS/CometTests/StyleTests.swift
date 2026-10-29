import XCTest

@testable import Comet

final class StyleTests: XCTestCase {
  func testLegacyStylesKeepTheirCSSAndGainDefaults() throws {
    let json = """
      [{"id":"11111111-1111-1111-1111-111111111111","name":"Quiet","note":"Dim","hosts":["example.com"],"excludedPaths":["/private"],"css":"body{color:black}","script":"","scriptEnabled":false,"enabled":true}]
      """
    let styles = try JSONDecoder().decode([SiteStyle].self, from: Data(json.utf8))
    let style = try XCTUnwrap(styles.first)
    XCTAssertEqual(style.schema, 1)
    XCTAssertEqual(style.theme, .website)
    XCTAssertNil(style.color)
    XCTAssertTrue(style.visualsEnabled)
    XCTAssertFalse(style.scriptEnabled)
    XCTAssertEqual(style.created, .distantPast)
    XCTAssertEqual(style.hidden, [])
    XCTAssertEqual(StyleMatch.combinedCSS(styles, for: URL(string: "https://example.com/a")!), "body{color:black}")
    XCTAssertTrue(StyleMatch.combinedCSS(styles, for: URL(string: "https://example.com/private/x")!).isEmpty)
    let round = try StyleTransfer.importData(try StyleTransfer.exportJSON(styles))
    XCTAssertEqual(round.map(\.name), ["Quiet"])
    XCTAssertEqual(round.map(\.css), ["body{color:black}"])
    XCTAssertEqual(round.map(\.schema), [1])
  }

  func testPaletteStaysReadableAndDoesNotInventATheme() {
    XCTAssertNil(StylePalette.paint(theme: .website, color: nil))
    let dark = StylePalette.paint(theme: .dark, color: nil)
    XCTAssertEqual(dark?.scheme, "dark")
    XCTAssertGreaterThanOrEqual(StyleRGB.contrast(try XCTUnwrap(dark).text, try XCTUnwrap(dark).background), 4.5)
    let light = StylePalette.paint(theme: .light, color: StyleColor(hex: "#E11D48"))
    XCTAssertGreaterThanOrEqual(StyleRGB.contrast(try XCTUnwrap(light).link, try XCTUnwrap(light).background), 4.5)
    XCTAssertGreaterThanOrEqual(StyleRGB.contrast(try XCTUnwrap(light).text, try XCTUnwrap(light).background), 4.5)
  }

  func testVisualCSSIsScopedHonestlyAndResetsWithoutDeletingCode() {
    var style = SiteStyle(id: UUID(), name: "A", hosts: ["example.com"], css: "/*custom*/", enabled: true, theme: .dark, contrast: 1.4, fontID: "avenir", textScale: 1.5, textCase: .upper)
    style.hidden = [StyleHidden(id: UUID(), selector: "#box", label: "Box", confidence: .high)]
    let css = StyleVisuals.appliedCSS(style)
    XCTAssertTrue(css.contains("/* comet-palette:"))
    XCTAssertTrue(css.contains("color-scheme: dark"))
    XCTAssertFalse(css.contains("invert("))
    XCTAssertTrue(css.contains(".comet-tone"))
    XCTAssertTrue(css.contains("contrast(1.4)"))
    XCTAssertTrue(css.contains("#comet-zap-root"))
    XCTAssertFalse(css.contains("zoom:"))
    XCTAssertTrue(css.contains("font-family: \"Avenir Next\""))
    XCTAssertTrue(css.contains("input[type=\"password\"]"))
    XCTAssertTrue(css.contains("calc(100% * 1.5)"))
    XCTAssertTrue(css.contains("text-transform: uppercase"))
    XCTAssertTrue(css.contains("text-transform: none"))
    XCTAssertTrue(css.contains("#box { display: none !important; }"))
    XCTAssertLessThan(css.range(of: "comet-palette")!.lowerBound, css.range(of: "/*custom*/")!.lowerBound)
    style.visualsEnabled = false
    let kept = StyleVisuals.appliedCSS(style)
    XCTAssertFalse(kept.contains("comet-palette"))
    XCTAssertFalse(kept.contains("comet-tone"))
    XCTAssertTrue(kept.contains("#box"))
    XCTAssertTrue(kept.contains("/*custom*/"))
    style.hidden = [StyleHidden(id: UUID(), selector: "div { color: red }", label: "Bad", confidence: .low)]
    XCTAssertFalse(StyleVisuals.hiddenCSS(style.hidden).contains("color"))
    style.resetVisuals()
    XCTAssertEqual(style.theme, .website)
    XCTAssertFalse(style.hasAdjustments)
    XCTAssertEqual(style.css, "/*custom*/")
    XCTAssertFalse(style.scriptEnabled)
  }

  func testLaterStylesAndTheUsersCSSWin() {
    let first = SiteStyle(id: UUID(), name: "One", hosts: ["example.com"], css: "/*one*/", enabled: true, theme: .light)
    let second = SiteStyle(id: UUID(), name: "Two", hosts: ["example.com"], css: "/*two*/", enabled: true, theme: .dark)
    let combined = StyleMatch.combinedCSS([first, second], for: URL(string: "https://example.com")!)
    let light = combined.range(of: "color-scheme: light")
    let one = combined.range(of: "/*one*/")
    let dark = combined.range(of: "color-scheme: dark")
    let two = combined.range(of: "/*two*/")
    XCTAssertLessThan(try XCTUnwrap(light).lowerBound, try XCTUnwrap(one).lowerBound)
    XCTAssertLessThan(try XCTUnwrap(one).lowerBound, try XCTUnwrap(dark).lowerBound)
    XCTAssertLessThan(try XCTUnwrap(dark).lowerBound, try XCTUnwrap(two).lowerBound)
  }

  func testDraftReplacesCodeWithoutChangingTheSavedStyle() {
    let style = SiteStyle(id: UUID(), name: "A", hosts: ["example.com"], css: "/*saved*/", enabled: true)
    let draft = StyleEngine.Draft(styleID: style.id, css: "/*draft*/", script: "var n = 1", scriptEnabled: true)
    let resolved = StyleDraft.resolve([style], draft: draft)
    XCTAssertEqual(resolved[0].css, "/*draft*/")
    XCTAssertTrue(resolved[0].scriptEnabled)
    XCTAssertEqual(style.css, "/*saved*/")
    XCTAssertFalse(style.scriptEnabled)
  }

  func testPlannerSeparatesNavigationFromVisualTweaks() {
    var memory = StyleApplyPlanner.Memory()
    let page = URL(string: "https://example.com/a")!
    var style = SiteStyle(
      id: UUID(), name: "A", hosts: ["example.com"], css: "body{}", script: "var x = 1", scriptEnabled: true, enabled: true)
    XCTAssertNil(StyleApplyPlanner.step(memory: &memory, loading: true, url: page, styles: [style]))
    XCTAssertTrue(memory.pending)
    XCTAssertEqual(StyleApplyPlanner.step(memory: &memory, loading: false, url: page, styles: [style])?.runScript, true)
    XCTAssertNil(StyleApplyPlanner.step(memory: &memory, loading: false, url: page, styles: [style]))
    style.contrast = 1.3
    let tweak = StyleApplyPlanner.step(memory: &memory, loading: false, url: page, styles: [style])
    XCTAssertEqual(tweak?.runScript, false)
    XCTAssertTrue(tweak?.css.contains("comet-tone") == true)
    XCTAssertNil(StyleApplyPlanner.step(memory: &memory, loading: true, url: page, styles: [style]))
    XCTAssertEqual(StyleApplyPlanner.step(memory: &memory, loading: false, url: page, styles: [style])?.runScript, true)
    XCTAssertNil(StyleApplyPlanner.step(memory: &memory, loading: false, url: URL(string: "file:///tmp/a")!, styles: [style]))
    XCTAssertNil(memory.css)
    let other = URL(string: "https://example.com/b")!
    XCTAssertEqual(StyleApplyPlanner.step(memory: &memory, loading: false, url: other, styles: [style])?.runScript, true)
    XCTAssertTrue(StyleMatch.combinedScript([style], for: URL(string: "https://evil.example.com")!).isEmpty)
  }

  func testSelectorsPreferStableIDsAndRejectBreakouts() {
    let stable = StyleNode(
      tag: "button", id: "save", idCount: 1, classes: ["btn"], classCount: ["btn": 4], attributes: ["data-testid": "save"],
      attributeCount: ["data-testid=save": 1], nth: 2, siblings: 3, text: "Save")
    XCTAssertEqual(StyleSelector.candidates(for: [stable]).first?.selector, "#save")
    XCTAssertEqual(StyleSelector.candidates(for: [stable]).first?.confidence, .high)
    let positional = StyleNode(
      tag: "div", id: "", idCount: 0, classes: [], classCount: [:], attributes: [:], attributeCount: [:], nth: 7, siblings: 9, text: "")
    let parent = StyleNode(
      tag: "main", id: "", idCount: 0, classes: [], classCount: [:], attributes: [:], attributeCount: [:], nth: 1, siblings: 1, text: "")
    let broad = StyleSelector.candidates(for: [positional, parent])
    XCTAssertEqual(broad.first?.selector, "main > div:nth-of-type(7)")
    XCTAssertEqual(broad.first?.confidence, .low)
    let named = StyleNode(
      tag: "button", id: "", idCount: 0, classes: [], classCount: [:], attributes: ["aria-label": "Buy now"],
      attributeCount: ["aria-label=Buy now": 1], nth: 1, siblings: 1, text: "Buy now")
    XCTAssertEqual(StyleSelector.candidates(for: [named]).first?.selector, "button[aria-label=\"Buy now\"]")
    XCTAssertFalse(StyleSelector.isSafe("div { color: red }"))
    XCTAssertFalse(StyleSelector.isSafe("body"))
    XCTAssertFalse(StyleSelector.isSafe("#comet-zap-root"))
    XCTAssertFalse(StyleSelector.isSafe("*"))
    XCTAssertTrue(StyleSelector.isSafe("#save"))
    XCTAssertNotNil(StyleScopeRules.problem("*"))
    XCTAssertNotNil(StyleScopeRules.problem("*.*.example.com"))
    XCTAssertNil(StyleScopeRules.problem("*.example.com"))
  }

  func testInjectionKeepsUserScriptAsData() {
    let source = StyleMatch.injection(
      css: "a\"b", script: "\");document.body.dataset.hacked='1'", scopes: [.init(hosts: ["example.com"], excludedPaths: [])], runScript: true)
    XCTAssertTrue(source.contains("\\\""))
    XCTAssertTrue(source.contains("comet-styles"))
    XCTAssertTrue(source.contains("new Function"))
    XCTAssertTrue(source.contains("onCleanup"))
    XCTAssertTrue(source.contains("cometHostMatches"))
    XCTAssertFalse(source.contains("keychain"))
    XCTAssertFalse(source.contains("evaluateJavaScript"))
    XCTAssertFalse(source.contains(".submit"))
    XCTAssertFalse(StyleTemplate.named("A", css: "").scriptEnabled)
  }

  func testPanelStaysInsideTheWindow() {
    let bounds = CGSize(width: 1000, height: 800)
    let panel = CGSize(width: 300, height: 500)
    let origin = StylePanelLayout.styleOrigin(offset: .zero, panel: panel, bounds: bounds, moved: false)
    XCTAssertEqual(origin, CGPoint(x: 684, y: 16))
    let shoved = StylePanelLayout.styleOrigin(offset: CGSize(width: 5000, height: 5000), panel: panel, bounds: bounds, moved: true)
    XCTAssertLessThanOrEqual(shoved.x + panel.width, bounds.width - 8)
    XCTAssertLessThanOrEqual(shoved.y + panel.height, bounds.height - 8)
    XCTAssertGreaterThanOrEqual(shoved.x, 8)
    let style = CGRect(x: 384, y: 16, width: 300, height: 400)
    let code = StylePanelLayout.codeOrigin(
      offset: .zero, panel: CGSize(width: 460, height: 400), bounds: CGSize(width: 700, height: 1100), styleFrame: style, moved: false)
    XCTAssertGreaterThan(code.y, style.maxY)
  }
}
