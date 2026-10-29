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

  func testLivePasskeyAuthorizationIsOneOfTheSystemStates() {
    let state = PasskeyAccess.current()
    XCTAssertTrue([PasskeyAuthorization.authorized, .denied, .notDetermined, .unavailable].contains(state))
  }
}
