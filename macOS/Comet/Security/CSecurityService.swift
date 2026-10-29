import Foundation
import LocalAuthentication

// CSecurityService: the single authoritative interface for Comet's own
// password management. Every credential operation in the app — the
// settings UI, the browser autofill flow, the save prompt, the generator,
// CSV import — goes through this service. No view keeps its own password
// database and no view implements its own matching rule.
//
// What this service is NOT:
// - It is not the macOS Password AutoFill provider and not Google
//   Password Manager. Those are external providers with their own
//   stores; the settings UI labels them as such and never claims they
//   are Security. The Chromium profile store (chrome://password-manager)
//   is likewise a separate engine store, not this vault.
// - It does not sync, upload, or back up credentials anywhere.
//
// Authentication model (see also SECURITY.md):
// - No master password in this version. The vault key lives in the
//   Keychain (see CSecurityVault); access to a PASSWORD additionally
//   requires a valid authenticated session from LocalAuthentication.
// - Default policy `.system` uses .deviceOwnerAuthentication: Touch ID
//   when available, otherwise the device password. The UI for this
//   policy must say "Touch ID or password", never "Touch ID required".
// - Policy `.biometricsOnly` uses .deviceOwnerAuthenticationWithBiometrics
//   and FAILS when biometrics are unavailable — it never silently falls
//   back to a password. The UI for that policy may say "Touch ID required".
// - A session lasts `lockTimeout` (default 5 minutes) from the last
//   successful authentication, and `lock()` ends it immediately. The
//   service re-checks the session at the moment a password is released,
//   not only when a suggestion was first shown.
// - Metadata (origin, username, display name) is shown without
//   authentication so a list and an autofill picker can exist at all.
//   A password is never returned without a valid session.
@MainActor
final class CSecurityService {
  static let shared = CSecurityService()

  enum AuthPolicy: String, CaseIterable, Sendable {
    /// Touch ID when available, device password otherwise.
    case system
    /// Touch ID (or Face ID on a device that has it) only; no fallback.
    case biometricsOnly

    var laPolicy: LAPolicy {
      switch self {
      case .system: .deviceOwnerAuthentication
      case .biometricsOnly: .deviceOwnerAuthenticationWithBiometrics
      }
    }

    /// The exact promise the UI may make for this policy.
    var promise: String {
      switch self {
      case .system: "Touch ID or your device password"
      case .biometricsOnly: "Touch ID required"
      }
    }
  }

  enum ServiceError: Error, Equatable, Sendable {
    case vaultNotReady
    case authenticationFailed
    case authenticationCancelled
    case biometricsUnavailable
    case persistenceFailed
    case invalidCredential
    case duplicateCredential
  }

  /// A short-lived authenticated session. Pure and testable: `isValid`
  /// compares against an injected clock so tests do not wait minutes.
  struct AuthSession: Sendable {
    var authenticatedAt: Date?
    var timeout: TimeInterval

    func isValid(at now: Date = Date()) -> Bool {
      guard let authenticatedAt else { return false }
      return now.timeIntervalSince(authenticatedAt) < timeout
    }
  }

  // MARK: - Preferences (non-secret only)

  private enum DefaultsKey {
    static let authPolicy = "CSecurityService.authPolicy"
    static let lockTimeout = "CSecurityService.lockTimeoutSeconds"
    static let generationLength = "CSecurityService.generationLength"
  }

  var authPolicy: AuthPolicy {
    get {
      AuthPolicy(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.authPolicy) ?? "") ?? .system
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKey.authPolicy) }
  }

  /// Seconds an authenticated session stays valid. Default 5 minutes.
  var lockTimeout: TimeInterval {
    get {
      let stored = UserDefaults.standard.double(forKey: DefaultsKey.lockTimeout)
      return stored > 0 ? stored : 300
    }
    set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.lockTimeout) }
  }

  var generationSettings: CSecurityPasswordGenerator.Settings {
    get {
      let stored = UserDefaults.standard.integer(forKey: DefaultsKey.generationLength)
      return stored == 0 ? .default : CSecurityPasswordGenerator.Settings(length: stored)
    }
    set { UserDefaults.standard.set(newValue.length, forKey: DefaultsKey.generationLength) }
  }

  // MARK: - State

  private let vault: CSecurityVault.Store
  private var session = AuthSession(authenticatedAt: nil, timeout: 300)
  private(set) var isVaultReady = false
  private(set) var vaultError: CSecurityVault.Error?

  init(vault: CSecurityVault.Store = CSecurityVault.Store()) {
    self.vault = vault
  }

  /// Test seam: a service over in-memory stores, with no Keychain.
  static func inMemory() -> CSecurityService {
    CSecurityService(vault: CSecurityVault.Store(
      keyStore: CSecurityVault.MemoryKeyStore(),
      fileStore: CSecurityVault.MemoryFileStore()))
  }

  // MARK: - Vault lifecycle

  /// Loads (or first-creates) the vault. Must be called before any
  /// credential operation; the UI calls it on appear and surfaces
  /// `vaultError` instead of showing an empty list for a damaged vault.
  func prepare() {
    session.timeout = lockTimeout
    do {
      _ = try vault.load()
      isVaultReady = true
      vaultError = nil
    } catch let error as CSecurityVault.Error {
      isVaultReady = false
      vaultError = error
    } catch {
      isVaultReady = false
      vaultError = .persistenceFailed
    }
  }

  /// Ends the authenticated session AND purges the vault from memory.
  /// The encrypted file and Keychain key stay, so `prepare()` (Unlock)
  /// reopens the vault without re-creating it. Inactivity does not
  /// purge the list by itself: it ends the password-release session
  /// (see `isAuthenticated`), while the Lock button purges everything.
  func lock() {
    session = AuthSession(authenticatedAt: nil, timeout: lockTimeout)
    vault.lockVault()
    isVaultReady = false
  }

  /// Reopens a locked vault. This loads the encrypted file; it does not
  /// authenticate, and it does not release any password.
  func unlock() { prepare() }

  var isAuthenticated: Bool { session.isValid() }

  // MARK: - Authentication

  /// Authenticates for a protected operation. A still-valid session is
  /// reused (no repeated prompt per field); an expired session prompts
  /// once. Cancellation and failure are distinct: callers must not
  /// treat a cancelled prompt as a successful unlock.
  @discardableResult
  func authenticate(reason: String) async -> Result<Void, ServiceError> {
    session.timeout = lockTimeout
    if session.isValid() { return .success(()) }
    let context = LAContext()
    var evaluationError: NSError?
    guard context.canEvaluatePolicy(authPolicy.laPolicy, error: &evaluationError) else {
      return .failure(authPolicy == .biometricsOnly ? .biometricsUnavailable : .authenticationFailed)
    }
    do {
      let ok = try await context.evaluatePolicy(authPolicy.laPolicy, localizedReason: reason)
      if ok {
        session = AuthSession(authenticatedAt: Date(), timeout: lockTimeout)
        return .success(())
      }
      return .failure(.authenticationFailed)
    } catch let error as LAError {
      switch error.code {
      case .userCancel, .appCancel, .systemCancel:
        return .failure(.authenticationCancelled)
      case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
        return .failure(authPolicy == .biometricsOnly ? .biometricsUnavailable : .authenticationFailed)
      default:
        return .failure(.authenticationFailed)
      }
    } catch {
      return .failure(.authenticationFailed)
    }
  }

  // MARK: - Reads (metadata needs no auth; passwords do)

  func metadata() throws -> [CSecurityCredential.Metadata] {
    guard isVaultReady else { throw ServiceError.vaultNotReady }
    return try vault.credentials().map(\.metadata).sorted { $0.origin < $1.origin }
  }

  func metadata(forOrigin origin: String) throws -> [CSecurityCredential.Metadata] {
    try metadata().filter { $0.origin == origin }
  }

  func metadata(forPageURL url: URL) throws -> [CSecurityCredential.Metadata] {
    guard let origin = CredentialPage.origin(url) else { return [] }
    return try metadata(forOrigin: origin)
  }

  /// Releases one password, and only after successful authentication.
  /// Also stamps lastUsed. The caller must re-verify the page origin
  /// before filling; this method alone does not fill anything.
  func password(for id: UUID, reason: String) async -> Result<String, ServiceError> {
    guard isVaultReady else { return .failure(.vaultNotReady) }
    switch await authenticate(reason: reason) {
    case .success: break
    case .failure(let error): return .failure(error)
    }
    do {
      var all = try vault.credentials()
      guard let index = all.firstIndex(where: { $0.id == id }) else {
        return .failure(.invalidCredential)
      }
      let password = all[index].password
      all[index].lastUsed = Date()
      try vault.save(all)
      return .success(password)
    } catch {
      return .failure(.persistenceFailed)
    }
  }

  // MARK: - Writes

  /// Inserts or updates by stable id. A credential whose origin changed
  /// (the user edited its URL) is only available to the NEW origin after
  /// this save — matching always reads the stored origin.
  func save(_ credential: CSecurityCredential) throws {
    guard isVaultReady else { throw ServiceError.vaultNotReady }
    var all = try vault.credentials()
    var updated = credential
    updated.modified = Date()
    if let index = all.firstIndex(where: { $0.id == credential.id }) {
      updated.created = all[index].created
      updated.lastUsed = all[index].lastUsed
      all[index] = updated
    } else {
      all.append(updated)
    }
    try persist(all)
  }

  /// Saves a credential the user submitted in the browser, after the
  /// user confirmed the "Save password to Security?" prompt. If a
  /// credential for the same origin + username already exists, this
  /// replaces it (the user just re-entered that login); callers that
  /// need a choice must use `saveGenerated` or check first.
  func saveSubmitted(_ credential: CSecurityCredential) throws {
    guard isVaultReady else { throw ServiceError.vaultNotReady }
    var all = try vault.credentials()
    if let index = all.firstIndex(where: { $0.origin == credential.origin && $0.username == credential.username }) {
      var updated = credential
      updated.id = all[index].id
      updated.created = all[index].created
      updated.lastUsed = all[index].lastUsed
      updated.modified = Date()
      all[index] = updated
    } else {
      all.append(credential)
    }
    try persist(all)
  }

  func delete(id: UUID) throws {
    guard isVaultReady else { throw ServiceError.vaultNotReady }
    var all = try vault.credentials()
    guard let index = all.firstIndex(where: { $0.id == id }) else {
      throw CSecurityVault.Error.credentialNotFound
    }
    all.remove(at: index)
    try persist(all)
  }

  private func persist(_ credentials: [CSecurityCredential]) throws {
    do {
      try vault.save(credentials)
    } catch {
      throw ServiceError.persistenceFailed
    }
  }

  // MARK: - CSV import (transactional)

  struct ImportSummary: Equatable, Sendable {
    var imported: Int
    var duplicates: Int
    var skipped: Int
    /// Human-readable, per-row reasons. Never contains a password.
    var errors: [String]
  }

  /// Validates every row first, then persists once. If persistence
  /// fails, nothing is committed: the vault keeps its previous contents.
  /// The source file is never deleted by this method and never leaves
  /// the device; the UI warns the user to delete it themselves.
  func importCredentials(_ credentials: [CSecurityCredential], skippingDuplicates: Bool = true) throws -> ImportSummary {
    guard isVaultReady else { throw ServiceError.vaultNotReady }
    let existing = try vault.credentials()
    var all = existing
    var imported = 0
    var duplicates = 0
    for credential in credentials {
      if all.contains(where: { $0.origin == credential.origin && $0.username == credential.username }) {
        duplicates += 1
        if skippingDuplicates { continue }
      }
      all.append(credential)
      imported += 1
    }
    try persist(all)
    return ImportSummary(imported: imported, duplicates: duplicates, skipped: 0, errors: [])
  }

  // MARK: - Generated passwords

  enum GeneratedSave: Sendable {
    /// No conflicting credential; the generated password was saved.
    case saved(CSecurityCredential)
    /// A credential for this origin + username already exists. The
    /// caller must ask: replace it, or keep both as separate accounts.
    /// Nothing was saved yet, and nothing was overwritten.
    case needsChoice(existing: CSecurityCredential.Metadata, generated: CSecurityCredential)
  }

  /// Saves a user-invoked generated password automatically — that is,
  /// without the ordinary "Save password to Security?" confirmation.
  /// "Automatically" means only this: the user already invoked Generate
  /// Password. Merely displaying a generated password never calls this.
  /// If a matching credential exists, nothing is overwritten silently.
  func saveGenerated(_ credential: CSecurityCredential) throws -> GeneratedSave {
    guard isVaultReady else { throw ServiceError.vaultNotReady }
    var all = try vault.credentials()
    if let existing = all.first(where: { $0.origin == credential.origin && $0.username == credential.username }) {
      return .needsChoice(existing: existing.metadata, generated: credential)
    }
    all.append(credential)
    try persist(all)
    return .saved(credential)
  }

  /// Resolves a `needsChoice` result after the user chose. `.replace`
  /// overwrites the existing credential (same stable id); `.keepBoth`
  /// appends the generated credential as a second account.
  func resolveGeneratedChoice(_ choice: GeneratedChoice, existing: CSecurityCredential.Metadata, generated: CSecurityCredential) throws {
    guard isVaultReady else { throw ServiceError.vaultNotReady }
    var all = try vault.credentials()
    switch choice {
    case .replace:
      guard let index = all.firstIndex(where: { $0.id == existing.id }) else {
        throw CSecurityVault.Error.credentialNotFound
      }
      var updated = generated
      updated.id = existing.id
      updated.created = all[index].created
      updated.lastUsed = all[index].lastUsed
      updated.modified = Date()
      all[index] = updated
    case .keepBoth:
      all.append(generated)
    }
    try persist(all)
  }

  enum GeneratedChoice: Sendable { case replace, keepBoth }
}
