import CryptoKit
import Foundation
import XCTest

@testable import Comet

// Tests for CSecurityService and its vault, CSV import, generation, and
// origin matching. All credentials here are fake fixtures. No test reads
// the real Keychain or the real vault file: the vault under test is
// constructed over in-memory stores. Nothing in this file logs a
// password, and no test uses a real user password.
final class CSecurityTests: XCTestCase {
  private func service() -> CSecurityService {
    let service = CSecurityService.inMemory()
    service.prepare()
    return service
  }

  // MARK: - Vault

  func testVaultRoundTripEncryptsAndRetrieves() throws {
    let store = CSecurityVault.Store(
      keyStore: CSecurityVault.MemoryKeyStore(),
      fileStore: CSecurityVault.MemoryFileStore())
    let credential = CSecurityCredential.make(
      url: "https://example.com/login", username: "ada@example.com", password: "fake-password-1")
    XCTAssertNotNil(credential)
    try store.load()
    try store.save([credential!])
    XCTAssertEqual(try store.credentials().count, 1)
    XCTAssertEqual(try store.credentials().first?.password, "fake-password-1")
  }

  func testVaultFileNeverContainsPlaintextPassword() throws {
    let files = CSecurityVault.MemoryFileStore()
    let store = CSecurityVault.Store(keyStore: CSecurityVault.MemoryKeyStore(), fileStore: files)
    try store.load()
    let credential = CSecurityCredential.make(
      url: "https://example.com/login", username: "ada@example.com", password: "fake-password-1")!
    try store.save([credential])
    let raw = try files.read()
    XCTAssertNotNil(raw)
    XCTAssertFalse(raw!.contains("fake-password-1".data(using: .utf8)!))
    XCTAssertFalse(raw!.contains("ada@example.com".data(using: .utf8)!))
  }

  func testCorruptedVaultIsNotOverwrittenWithEmptyVault() throws {
    let keys = CSecurityVault.MemoryKeyStore()
    let files = CSecurityVault.MemoryFileStore()
    let store = CSecurityVault.Store(keyStore: keys, fileStore: files)
    try store.load()
    let credential = CSecurityCredential.make(
      url: "https://example.com/login", username: "ada@example.com", password: "fake-password-1")!
    try store.save([credential])
    // This was the first save, so there is no previous good copy yet.
    // Corrupting the only copy must throw on reopen — and must not be
    // "repaired" by writing an empty vault over it.
    files.corruptCurrent()
    let reopened = CSecurityVault.Store(keyStore: keys, fileStore: files)
    XCTAssertThrowsError(try reopened.load()) { error in
      XCTAssertEqual(error as? CSecurityVault.Error, .vaultCorrupted)
    }
    // The damaged file is still there, untouched by the failed load.
    XCTAssertEqual(try files.read(), Data("not a vault".utf8))
  }

  func testInterruptedWriteRecoversPreviousGoodVault() throws {
    let keys = CSecurityVault.MemoryKeyStore()
    let files = CSecurityVault.MemoryFileStore()
    let store = CSecurityVault.Store(keyStore: keys, fileStore: files)
    try store.load()
    let first = CSecurityCredential.make(
      url: "https://example.com/login", username: "ada@example.com", password: "fake-password-1")!
    try store.save([first])
    let second = CSecurityCredential.make(
      url: "https://example.org/login", username: "grace@example.org", password: "fake-password-2")!
    try store.save([first, second])
    // Simulate an interrupted write: the current file is garbage, but
    // the previous good copy (first save) is intact.
    files.corruptCurrent()
    let reopened = CSecurityVault.Store(keyStore: keys, fileStore: files)
    let recovered = try reopened.load()
    XCTAssertEqual(recovered.count, 1)
    XCTAssertEqual(recovered.first?.origin, "https://example.com")
  }

  func testSaveBeforeLoadRefuses() {
    let store = CSecurityVault.Store(
      keyStore: CSecurityVault.MemoryKeyStore(),
      fileStore: CSecurityVault.MemoryFileStore())
    XCTAssertThrowsError(try store.save([])) { error in
      XCTAssertEqual(error as? CSecurityVault.Error, .vaultNotLoaded)
    }
  }

  // MARK: - Origin matching

  func testSecurityMatchingIsStrictOriginOnly() {
    let credential = CSecurityCredential.make(
      url: "https://example.com/login", username: "ada@example.com", password: "fake-password-1")!
    XCTAssertTrue(CSecurityCredential.matches(credential, pageURL: URL(string: "https://example.com/other")!))
    XCTAssertFalse(CSecurityCredential.matches(credential, pageURL: URL(string: "https://evil.example.com/")!))
    XCTAssertFalse(CSecurityCredential.matches(credential, pageURL: URL(string: "https://example.com.evil.example/")!))
    XCTAssertFalse(CSecurityCredential.matches(credential, pageURL: URL(string: "http://example.com/")!))
    XCTAssertFalse(CSecurityCredential.matches(credential, pageURL: URL(string: "https://example.com:8443/")!))
  }

  func testBareHostNormalisesToHTTPSOrigin() {
    let credential = CSecurityCredential.make(
      url: "example.com/login", username: "ada", password: "fake-password-1")
    XCTAssertEqual(credential?.origin, "https://example.com")
    XCTAssertNil(CSecurityCredential.make(url: "javascript:alert(1)", username: "ada", password: "fake-password-1"))
    XCTAssertNil(CSecurityCredential.make(url: "file:///tmp/x.html", username: "ada", password: "fake-password-1"))
  }

  // MARK: - CSV

  func testCSVQuotedCommasEscapedQuotesAndMultiline() {
    let text = """
      name,url,username,password
      "My, Site",https://example.com,ada,"pass, ""quoted"" word"
      "Multi
      Line",https://example.org,grace,"line1
      line2"
      """
    let rows = CSecurityCSV.parse(text)
    XCTAssertNotNil(rows)
    XCTAssertEqual(rows?.count, 3)
    let mapping = CSecurityCSV.detectMapping(headerRow: rows?.first)
    XCTAssertTrue(mapping.hasHeaderRow)
    let outcomes = CSecurityCSV.validate(
      rows: Array(rows!.dropFirst()), mapping: mapping, existing: [])
    XCTAssertEqual(outcomes.count, 2)
    if case let .credential(first) = outcomes[0] {
      XCTAssertEqual(first.password, "pass, \"quoted\" word")
      XCTAssertEqual(first.displayName, "My, Site")
    } else {
      XCTFail("First row should parse as a credential")
    }
    if case let .credential(second) = outcomes[1] {
      XCTAssertTrue(second.password.contains("\n"))
    } else {
      XCTFail("Second row should parse as a credential")
    }
  }

  func testCSVHeaderVariantsAndMalformedRows() {
    let text = """
      Title,Website,Email,Pass
      Example,https://example.com,ada@example.com,fake-password-1
      Broken,https://example.com,,
      ,https://example.com,ada@example.com,fake-password-2
      """
    let rows = CSecurityCSV.parse(text)!
    let mapping = CSecurityCSV.detectMapping(headerRow: rows.first)
    XCTAssertTrue(mapping.hasHeaderRow)
    let outcomes = CSecurityCSV.validate(rows: Array(rows.dropFirst()), mapping: mapping, existing: [])
    XCTAssertEqual(outcomes.count, 3)
    XCTAssertTrue(outcomes[0].isCredential)
    XCTAssertTrue(outcomes[1].isSkipped)
    XCTAssertTrue(outcomes[2].isSkipped)
  }

  func testCSVUnterminatedQuoteIsMalformed() {
    XCTAssertNil(CSecurityCSV.parse("name,url,username,password\n\"open,https://example.com,ada,fake"))
  }

  func testCSVImportIsTransactionalOnPersistenceFailure() throws {
    // A file store that always fails writes: the service must report
    // failure and the vault must keep its previous contents.
    final class FailingStore: CSecurityVault.FileStore, @unchecked Sendable {
      func read() throws -> Data? { nil }
      func readBackup() throws -> Data? { nil }
      func write(_ data: Data) throws { throw CSecurityVault.Error.persistenceFailed }
    }
    let vault = CSecurityVault.Store(keyStore: CSecurityVault.MemoryKeyStore(), fileStore: FailingStore())
    let service = CSecurityService(vault: vault)
    service.prepare()
    XCTAssertTrue(service.isVaultReady)
    let credential = CSecurityCredential.make(
      url: "https://example.com/login", username: "ada", password: "fake-password-1")!
    XCTAssertThrowsError(try service.importCredentials([credential]))
    XCTAssertEqual(try service.metadata().count, 0)
  }

  // MARK: - Generation

  func testGeneratedPasswordsMeetPolicyAcrossLengths() throws {
    for length in 8...12 {
      for _ in 0..<25 {
        let password = try CSecurityPasswordGenerator.generate(length: length)
        XCTAssertEqual(password.count, length)
        XCTAssertTrue(CSecurityPasswordGenerator.satisfiesPolicy(password, lengthRange: length...length))
      }
    }
  }

  func testGenerationSettingsClampTo8Through12() {
    XCTAssertEqual(CSecurityPasswordGenerator.Settings(length: 4).length, 8)
    XCTAssertEqual(CSecurityPasswordGenerator.Settings(length: 20).length, 12)
    XCTAssertEqual(CSecurityPasswordGenerator.Settings(length: 10).length, 10)
  }

  func testGeneratedSaveDoesNotSilentlyOverwrite() throws {
    let service = service()
    let existing = CSecurityCredential.make(
      url: "https://example.com/login", username: "ada", password: "fake-password-1")!
    try service.save(existing)
    let generated = CSecurityCredential.make(
      url: "https://example.com/login", username: "ada", password: "fake-password-9")!
    let result = try service.saveGenerated(generated)
    if case let .needsChoice(existingMetadata, _) = result {
      XCTAssertEqual(existingMetadata.username, "ada")
      // Nothing overwritten yet.
      XCTAssertEqual(try service.metadata().count, 1)
    } else {
      XCTFail("Expected needsChoice for an existing origin + username")
    }
    try service.resolveGeneratedChoice(.keepBoth, existing: try service.metadata().first!, generated: generated)
    XCTAssertEqual(try service.metadata().count, 2)
  }

  // MARK: - Auth session

  func testAuthSessionExpires() {
    let fresh = CSecurityService.AuthSession(authenticatedAt: Date(), timeout: 300)
    XCTAssertTrue(fresh.isValid())
    let stale = CSecurityService.AuthSession(
      authenticatedAt: Date().addingTimeInterval(-301), timeout: 300)
    XCTAssertFalse(stale.isValid())
    XCTAssertFalse(CSecurityService.AuthSession(authenticatedAt: nil, timeout: 300).isValid())
  }

  // MARK: - Credential management

  func testAddSearchEditDeleteThroughService() throws {
    let service = service()
    let credential = CSecurityCredential.make(
      url: "https://example.com/login", username: "ada", password: "fake-password-1",
      displayName: "Example")!
    try service.save(credential)
    XCTAssertEqual(try service.metadata(forOrigin: "https://example.com").count, 1)
    // Edit the URL: the credential must move to the new origin only.
    var edited = credential
    edited.url = "https://example.org/login"
    edited.origin = "https://example.org"
    try service.save(edited)
    XCTAssertEqual(try service.metadata(forOrigin: "https://example.com").count, 0)
    XCTAssertEqual(try service.metadata(forOrigin: "https://example.org").count, 1)
    // Stable id preserved across the edit.
    XCTAssertEqual(try service.metadata(forOrigin: "https://example.org").first?.id, credential.id)
    try service.delete(id: credential.id)
    XCTAssertEqual(try service.metadata().count, 0)
  }

  func testSaveScriptNeverSubmitsOrReadsValuesOnProbe() {
    XCTAssertFalse(CSecuritySaveScript.install.contains("preventDefault"))
    XCTAssertFalse(CSecuritySaveScript.install.contains(".submit("))
    XCTAssertFalse(CSecuritySaveScript.takePending.contains("password"))
    // The take script only moves an already-captured pending value; it
    // must not contain a field query of its own.
    XCTAssertFalse(CSecuritySaveScript.takePending.contains("querySelector"))
  }

  func testMigrationConverter() {
    let imported = ImportedPassword(url: "https://example.com", username: "ada", password: "fake-password-1")
    XCTAssertEqual(CSecurityMigration.credential(from: imported)?.origin, "https://example.com")
    let bad = ImportedPassword(url: "javascript:alert(1)", username: "ada", password: "fake-password-1")
    XCTAssertNil(CSecurityMigration.credential(from: bad))
  }
}

private extension CSecurityCSV.RowOutcome {
  var isCredential: Bool { if case .credential = self { true } else { false } }
  var isSkipped: Bool { if case .skipped = self { true } else { false } }
}
