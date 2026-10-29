import JavaScriptCore
import XCTest

@testable import Comet

final class CredentialTests: XCTestCase {
  func testOnlyWebOriginsCanBeFilled() {
    XCTAssertEqual(CredentialPage.origin(URL(string: "https://example.com/login")!), "https://example.com")
    XCTAssertNil(CredentialPage.origin(URL(string: "javascript:alert(1)")!))
    XCTAssertNil(CredentialPage.origin(URL(string: "file:///tmp/login.html")!))
    XCTAssertFalse(CredentialPage.sameOrigin(URL(string: "https://example.com/a")!, URL(string: "https://evil.example/a")!))
    XCTAssertTrue(CredentialPage.sameOrigin(URL(string: "https://example.com/a")!, URL(string: "https://example.com/other")!))
  }

  func testPasswordScriptDoesNotSubmitOrBreakOutOfJSON() {
    let script = PasswordFillScript.source(username: "a\"};alert(1);//", password: "p")
    XCTAssertTrue(script.contains("const username = \""))
    XCTAssertFalse(script.contains("username = a"))
    XCTAssertFalse(script.contains(".submit"))
    XCTAssertFalse(script.contains("requestSubmit"))
  }

  func testPasskeyStateMappingDoesNotInventAccess() {
    XCTAssertEqual(PasskeyAuthorization.map(.authorized), .authorized)
    XCTAssertEqual(PasskeyAuthorization.map(.denied), .denied)
    XCTAssertEqual(PasskeyAuthorization.map(.notDetermined), .notDetermined)
  }

  func testProbeScriptClassifiesLoginFields() {
    func run(_ element: String, documentHasPassword: Bool) -> String {
      let context = JSContext()!
      context.evaluateScript(
        """
        var document = {
          documentElement: { dataset: {} },
          addEventListener: function() {},
          querySelector: function(sel) {
            if (String(sel).indexOf(":focus") !== -1) return document._focused || null;
            if (String(sel).indexOf("password") !== -1) return \(documentHasPassword ? "{}" : "null");
            return null;
          },
          _focused: \(element)
        };
        document.activeElement = \(element);
        """)
      return context.evaluateScript(PasswordFieldProbe.script)?.toString() ?? ""
    }
    let password = """
      { tagName: "INPUT", getAttribute: function(n) { if (n === "type") return "password"; if (n === "autocomplete") return "current-password"; return ""; }, form: { querySelector: function() { return {}; } } }
      """
    let username = """
      { tagName: "INPUT", getAttribute: function(n) { if (n === "type") return "email"; if (n === "autocomplete") return "username"; return ""; }, form: { querySelector: function() { return {}; } } }
      """
    let search = """
      { tagName: "INPUT", getAttribute: function(n) { if (n === "type") return "search"; if (n === "autocomplete") return ""; return ""; }, form: null }
      """
    XCTAssertTrue(run(password, documentHasPassword: true).hasPrefix("password"))
    XCTAssertTrue(run(username, documentHasPassword: true).hasPrefix("username"))
    XCTAssertEqual(run(search, documentHasPassword: false), "")
    let parsed = PasswordFieldGeometry.parse("password@8,20,220,28|8,64,220,28")
    XCTAssertEqual(parsed?.kind, "password")
    XCTAssertEqual(parsed?.username, CGRect(x: 8, y: 20, width: 220, height: 28))
    XCTAssertEqual(parsed?.password, CGRect(x: 8, y: 64, width: 220, height: 28))
    XCTAssertNil(PasswordFieldGeometry.parse("search@1,2,3,4|"))
    XCTAssertNil(PasswordFieldGeometry.parse("password@1,2|3,4,5,6")?.username)
    XCTAssertEqual(PasswordFieldGeometry.parse("password@1,2|3,4,5,6")?.password, CGRect(x: 3, y: 4, width: 5, height: 6))
    XCTAssertTrue(PasswordFillScript.source(username: "a", password: "b", moveFocus: false).contains("field.value"))
    XCTAssertFalse(PasswordFillScript.source(username: "a", password: "b", moveFocus: false).contains("field.focus"))
    XCTAssertEqual(PasswordFieldProbe.isLoginField(tag: "INPUT", type: "password", autocomplete: "", formHasPassword: true), "password")
    XCTAssertEqual(PasswordFieldProbe.isLoginField(tag: "INPUT", type: "text", autocomplete: "username", formHasPassword: false), "")
    XCTAssertFalse(PasswordFieldProbe.script.contains(".submit"))
    XCTAssertFalse(PasswordFieldProbe.script.contains(".value"))
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/login.html")
    let html = (try? String(contentsOf: fixture, encoding: .utf8)) ?? ""
    XCTAssertTrue(html.contains("autocomplete=\"username\""))
    XCTAssertTrue(html.contains("type=\"password\""))
    XCTAssertTrue(html.contains("autocomplete=\"current-password\""))
  }

  func testLivePasskeyAuthorizationIsOneOfTheSystemStates() {
    let state = PasskeyAccess.current()
    XCTAssertTrue([PasskeyAuthorization.authorized, .denied, .notDetermined, .unavailable].contains(state))
  }
}
