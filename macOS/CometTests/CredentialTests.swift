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

  func testOriginIncludesNonDefaultPorts() {
    XCTAssertEqual(CredentialPage.origin(URL(string: "https://example.com:8443/login")!), "https://example.com:8443")
    XCTAssertFalse(CredentialPage.sameOrigin(URL(string: "https://example.com/login")!, URL(string: "https://example.com:8443/login")!))
    XCTAssertTrue(CredentialPage.sameOrigin(URL(string: "https://example.com:443/login")!, URL(string: "https://example.com/login")!))
    XCTAssertEqual(CredentialPage.origin(URL(string: "http://example.com:8080/")!), "http://example.com:8080")
    XCTAssertEqual(CredentialPage.origin(URL(string: "https://EXAMPLE.com/")!), "https://example.com")
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
    // A username step has no password field yet, so autocomplete="username"
    // qualifies on its own. A bare email field without a password does not,
    // so newsletter and search forms are not treated as login forms.
    XCTAssertEqual(PasswordFieldProbe.isLoginField(tag: "INPUT", type: "text", autocomplete: "username", formHasPassword: false), "username")
    XCTAssertEqual(PasswordFieldProbe.isLoginField(tag: "INPUT", type: "email", autocomplete: "email", formHasPassword: false), "")
    XCTAssertFalse(PasswordFieldProbe.script.contains(".submit"))
    XCTAssertFalse(PasswordFieldProbe.script.contains(".value"))
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/login.html")
    let html = (try? String(contentsOf: fixture, encoding: .utf8)) ?? ""
    XCTAssertTrue(html.contains("autocomplete=\"username\""))
    XCTAssertTrue(html.contains("type=\"password\""))
    XCTAssertTrue(html.contains("autocomplete=\"current-password\""))
  }

  func testProbeScriptHandlesUsernameOnlyStepAndSameOriginFrame() {
    // Username-only step: no password field anywhere, only autocomplete="username".
    let stepContext = JSContext()!
    stepContext.evaluateScript(
      """
      var user = { tagName: "INPUT", getAttribute: function(n) { if (n === "type") return "text"; if (n === "autocomplete") return "username"; return ""; }, form: null, getBoundingClientRect: function() { return {x: 5, y: 20, width: 180, height: 28}; } };
      var document = {
        documentElement: { dataset: {} },
        addEventListener: function() {},
        querySelector: function(sel) {
          if (String(sel).indexOf(":focus") !== -1) return user;
          if (String(sel).indexOf("password") !== -1) return null;
          if (String(sel).indexOf('autocomplete="username"') !== -1) return user;
          return null;
        },
        querySelectorAll: function() { return []; }
      };
      """)
    XCTAssertEqual(stepContext.evaluateScript(PasswordFieldProbe.script)?.toString(), "username@5,20,180,28|")

    // Same-origin frame: the password field lives in the frame, and its rect
    // is reported offset by the frame's position on the page.
    let frameContext = JSContext()!
    frameContext.evaluateScript(
      """
      var frameDoc = {
        querySelector: function(sel) {
          if (String(sel).indexOf("password") !== -1) return { getBoundingClientRect: function() { return {x: 20, y: 30, width: 200, height: 30}; } };
          return null;
        }
      };
      var frame = { contentDocument: frameDoc, getBoundingClientRect: function() { return {x: 100, y: 200, width: 400, height: 300}; } };
      var document = {
        documentElement: { dataset: {} },
        addEventListener: function() {},
        querySelector: function(sel) {
          if (String(sel).indexOf(":focus") !== -1) return null;
          return null;
        },
        querySelectorAll: function(sel) { return [frame]; }
      };
      """)
    XCTAssertEqual(frameContext.evaluateScript(PasswordFieldProbe.script)?.toString(), "present@|120,230,200,30")
    XCTAssertTrue(PasswordFieldProbe.script.contains("contentDocument"))
    XCTAssertFalse(PasswordFieldProbe.script.contains(".value"))
  }

  func testUsernameOnlyGeometryAndFillScriptDoNotSubmit() {
    let target = PasswordFieldGeometry.parse("username@8,20,220,28|")
    XCTAssertEqual(target?.kind, "username")
    XCTAssertEqual(target?.username, CGRect(x: 8, y: 20, width: 220, height: 28))
    XCTAssertNil(target?.password)
    let script = PasswordFillScript.source(username: "a", password: "")
    XCTAssertFalse(script.contains(".submit"))
    XCTAssertFalse(script.contains("requestSubmit"))
    XCTAssertTrue(script.contains("no-password-field"))
  }

  func testGooglePasswordManagerIsNotReportedAsConnected() {
    XCTAssertFalse(PasswordAutofillPolicy.googleSyncAvailable)
    XCTAssertEqual(PasswordAutofillPolicy.googleStatus, "Not available")
    XCTAssertEqual(PasswordAutofillPolicy.provider, "macOS Password AutoFill")
    XCTAssertEqual(PasswordAutofillPolicy.googleManager.host(), "passwords.google.com")
    XCTAssertTrue(PasswordAutofillPolicy.googleLimitation.contains("not connected"))
    XCTAssertTrue(PasswordAutofillPolicy.googleLimitation.contains("does not give Comet"))
    XCTAssertTrue(PasswordAutofillPolicy.csvWarning.contains("text file"))
    XCTAssertTrue(PasswordAutofillPolicy.importSteps.joined(separator: " ").contains("will not open another app"))
    XCTAssertFalse(PasswordAutofillPolicy.importSteps.joined(separator: " ").contains("password123"))
    XCTAssertTrue(PasswordAutofillPolicy.storage.contains("not submitted"))
    // The macOS copy is a separate step from the Google import, and it must
    // never be described as a sync.
    let macOSSteps = PasswordAutofillPolicy.macOSImportSteps.joined(separator: " ")
    XCTAssertTrue(macOSSteps.contains("Passwords app"))
    XCTAssertTrue(macOSSteps.contains("Import Passwords from File"))
    XCTAssertTrue(macOSSteps.contains("AutoFill & Passwords"))
    XCTAssertTrue(PasswordAutofillPolicy.macOSImportNote.contains("not a sync"))
    XCTAssertFalse(PasswordAutofillPolicy.macOSImportNote.contains("syncs"))
  }

  func testPrivateWindowsAndOtherOriginsCannotBeFilled() {
    let login = URL(string: "https://example.com/login")!
    XCTAssertEqual(PasswordFillDecision.canRequest(privateTab: true, url: login), PasswordAutofillPolicy.privateWindow)
    XCTAssertNil(PasswordFillDecision.canRequest(privateTab: false, url: login))
    XCTAssertEqual(
      PasswordFillDecision.canRequest(privateTab: false, url: URL(string: "file:///tmp/login.html")!),
      PasswordAutofillPolicy.webOnly)
    XCTAssertEqual(
      PasswordFillDecision.canApply(requested: login, current: URL(string: "https://evil.example/login")!),
      PasswordAutofillPolicy.pageChanged)
    XCTAssertEqual(PasswordFillDecision.canApply(requested: login, current: nil), PasswordAutofillPolicy.pageChanged)
    XCTAssertNil(PasswordFillDecision.canApply(requested: login, current: URL(string: "https://example.com/account")!))
  }

  func testPageExtractOmitsFormFields() {
    XCTAssertTrue(PageExtractor.script.contains("input, textarea, select"))
    XCTAssertFalse(PageExtractor.script.contains("input.value"))
  }

  func testLivePasskeyAuthorizationIsOneOfTheSystemStates() {
    let state = PasskeyAccess.current()
    XCTAssertTrue([PasskeyAuthorization.authorized, .denied, .notDetermined, .unavailable].contains(state))
  }
}
