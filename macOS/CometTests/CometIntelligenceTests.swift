import XCTest

@testable import Comet

final class CometIntelligenceTests: XCTestCase {
  func testLegacyAISettingsDecode() throws {
    let data = Data(#"{"isEnabled":true,"provider":"openai","model":"gpt-4o-mini"}"#.utf8)
    let settings = try JSONDecoder().decode(AISettings.self, from: data)
    XCTAssertTrue(settings.isEnabled)
    XCTAssertEqual(settings.provider, .openai)
    XCTAssertTrue(settings.agent)
    XCTAssertTrue(settings.confirmAgentActions)
    XCTAssertFalse(settings.allowInsecureHTTP)
  }

  func testGeminiParse() throws {
    let data = Data(#"{"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}"#.utf8)
    let response = try GeminiAPI.parse(data, settings: AISettings(provider: .gemini, model: "gemini-2.0-flash"))
    XCTAssertEqual(response.text, "Hello")
    XCTAssertEqual(response.provider, .gemini)
  }

  func testEndpointPolicyBlocksPlainHTTP() {
    XCTAssertTrue(EndpointPolicy.allows(URL(string: "https://api.openai.com/v1")!, allowInsecureHTTP: false))
    XCTAssertTrue(EndpointPolicy.allows(URL(string: "http://127.0.0.1:11434/v1")!, allowInsecureHTTP: false))
    XCTAssertFalse(EndpointPolicy.allows(URL(string: "http://example.com/v1")!, allowInsecureHTTP: false))
    XCTAssertTrue(EndpointPolicy.allows(URL(string: "http://example.com/v1")!, allowInsecureHTTP: true))
  }

  func testAgentProtocolRejectsProseAroundJSON() {
    let text = """
      I will click it. {"action":"tool","name":"click_element","arguments":{"selector":"button"}}
      """
    if case .answer = AgentProtocol.parse(text) {} else { XCTFail("prose must not become a tool call") }
  }

  func testAgentProtocolParsesAToolAndAFinalAnswer() {
    let call = AgentProtocol.parse(#"{"action":"tool","name":"get_page_text","arguments":{}}"#)
    guard case let .call(tool) = call else { return XCTFail("expected a tool") }
    XCTAssertEqual(tool.name, "get_page_text")
    let answer = AgentProtocol.parse(#"{"action":"final","text":"Done."}"#)
    guard case let .answer(text) = answer else { return XCTFail("expected an answer") }
    XCTAssertEqual(text, "Done.")
  }

  func testUnknownToolIsRejected() {
    let turn = AgentProtocol.parse(#"{"action":"tool","name":"send_email","arguments":{}}"#)
    guard case .rejected = turn else { return XCTFail("unknown tools must not run") }
  }

  func testNavigationAlwaysNeedsConfirmation() {
    XCTAssertTrue(AgentProtocol.needsConfirmation("navigate_to_url", confirmInteractions: false))
    XCTAssertFalse(AgentProtocol.needsConfirmation("get_page_text", confirmInteractions: true))
    XCTAssertTrue(AgentProtocol.needsConfirmation("click_element", confirmInteractions: true))
    XCTAssertFalse(AgentProtocol.needsConfirmation("click_element", confirmInteractions: false))
  }

  func testSelectorAndURLValidation() {
    XCTAssertNil(AgentTools.safeSelector("javascript:alert(1)"))
    XCTAssertNil(AgentTools.safeSelector("div { color: red }"))
    XCTAssertEqual(AgentTools.safeSelector("button.buy"), "button.buy")
    XCTAssertNil(AgentTools.httpURL("file:///etc/passwd"))
    XCTAssertEqual(AgentTools.httpURL("https://example.com/a")?.host(), "example.com")
  }

  func testStyleHostIsolation() {
    var style = StyleTemplate.named("Readability", css: "body{}")
    style.enabled = true
    style.hosts = ["example.com"]
    XCTAssertTrue(StyleMatch.matches(URL(string: "https://example.com/a")!, style))
    XCTAssertFalse(StyleMatch.matches(URL(string: "https://evil.example.com/a")!, style))
    XCTAssertFalse(StyleMatch.matches(URL(string: "https://example.com.evil.test/a")!, style))
    style.hosts = ["*.example.com"]
    style.excludedPaths = ["/private"]
    XCTAssertTrue(StyleMatch.matches(URL(string: "https://news.example.com/story")!, style))
    XCTAssertFalse(StyleMatch.matches(URL(string: "https://news.example.com/private/x")!, style))
    XCTAssertFalse(StyleMatch.combinedScript([style], for: URL(string: "https://news.example.com/story")!).contains("alert"))
  }

  func testDisabledStyleDoesNotMatch() {
    var style = StyleTemplate.named("Width", css: "body{}")
    style.hosts = ["example.com"]
    style.enabled = false
    XCTAssertTrue(StyleMatch.combinedCSS([style], for: URL(string: "https://example.com")!).isEmpty)
  }

  func testDeveloperModePolicy() {
    let local = URL(string: "http://localhost:3000")!
    let web = URL(string: "https://example.com")!
    XCTAssertTrue(DeveloperModePolicy.showsChrome(url: local, enabled: false))
    XCTAssertFalse(DeveloperModePolicy.showsChrome(url: web, enabled: false))
    XCTAssertTrue(DeveloperModePolicy.showsChrome(url: web, enabled: true))
  }

  func testStartLinkRejectsScripts() {
    XCTAssertNil(StartLink.normalized("javascript:alert(1)"))
    XCTAssertEqual(StartLink.normalized("example.com/docs")?.absoluteString, "https://example.com/docs")
  }

  func testWeatherParsers() throws {
    let place = Data(#"{"results":[{"name":"Lisbon","latitude":38.7,"longitude":-9.1}]}"#.utf8)
    XCTAssertEqual(WeatherClient.parsePlace(place)?.name, "Lisbon")
    let forecast = Data(#"{"current":{"temperature_2m":17.2,"weather_code":2}}"#.utf8)
    XCTAssertEqual(WeatherClient.parseConditions(forecast)?.temperature, 17.2)
    XCTAssertEqual(WeatherClient.summary(for: 2), "Partly cloudy")
    XCTAssertNil(WeatherClient.parseConditions(Data("{}".utf8)))
  }

  func testDailyQuoteIsStableAndAttributed() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let first = QuoteLibrary.daily(on: date, extra: [])
    let second = QuoteLibrary.daily(on: date, extra: [])
    XCTAssertEqual(first, second)
    XCTAssertFalse(first?.author.isEmpty ?? true)
    XCTAssertFalse(first?.source.isEmpty ?? true)
  }

  func testAgentFeatureFollowsTheMasterSwitch() {
    var settings = AISettings(isEnabled: false, agent: true)
    XCTAssertFalse(settings.isOn(.agent))
    settings.isEnabled = true
    XCTAssertTrue(settings.isOn(.agent))
    settings.agent = false
    XCTAssertFalse(settings.isOn(.agent))
  }
}
