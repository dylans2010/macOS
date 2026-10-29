import Foundation

// The one credential model for Comet's own vault. Browser views, settings
// views, and login handlers never define their own copy of this model or
// their own matching rule: they go through CSecurityService, which stores
// and matches CSecurityCredential values only.
//
// A credential's matching identity is its normalised origin (see
// CredentialPage.origin: scheme + lowercased host + non-default port).
// Nothing else — never a page title, never page-supplied text — decides
// whether a credential may be offered on a page.
struct CSecurityCredential: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  /// The full website URL as entered or imported, for display and editing.
  var url: String
  /// Normalised origin, e.g. "https://example.com" or "https://example.com:8443".
  /// This is the only value autofill matching compares.
  var origin: String
  var username: String
  /// The secret. It lives in memory only while a vault operation needs it;
  /// persisted form is always the AES-GCM vault envelope (see CSecurityVault).
  /// Never log this value, never put it in UserDefaults, and never send it
  /// to a server, analytics, crash reporting, or an AI service.
  var password: String
  var displayName: String?
  var created: Date
  var modified: Date
  var lastUsed: Date?

  init(
    id: UUID = UUID(),
    url: String,
    origin: String,
    username: String,
    password: String,
    displayName: String? = nil,
    created: Date = Date(),
    modified: Date = Date(),
    lastUsed: Date? = nil
  ) {
    self.id = id
    self.url = url
    self.origin = origin
    self.username = username
    self.password = password
    self.displayName = displayName
    self.created = created
    self.modified = modified
    self.lastUsed = lastUsed
  }

  /// The metadata a list or an autofill picker may show without unlocking
  /// or decrypting a password. Passwords are never loaded into a list view.
  struct Metadata: Equatable, Identifiable, Sendable {
    var id: UUID
    var url: String
    var origin: String
    var username: String
    var displayName: String?
    var modified: Date
    var lastUsed: Date?

    var title: String {
      if let displayName, !displayName.isEmpty { return displayName }
      return origin
    }
  }

  var metadata: Metadata {
    Metadata(
      id: id, url: url, origin: origin, username: username,
      displayName: displayName, modified: modified, lastUsed: lastUsed)
  }
}

enum CSecurityCredentialValidation: Sendable {
  /// Validates a user-entered or imported credential's non-secret fields.
  /// Returns the normalised origin, or nil when the URL cannot be a website
  /// origin (non-http(s), no host, or a host with a space).
  static func origin(for urlString: String) -> String? {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // Accept a bare host ("example.com/login") the way browsers do, but
    // never accept a scheme other than http/https.
    let candidate: String
    if trimmed.contains("://") {
      candidate = trimmed
    } else {
      candidate = "https://" + trimmed
    }
    guard let url = URL(string: candidate) else { return nil }
    return CredentialPage.origin(url)
  }

  static func normalisedURL(for urlString: String) -> String? {
    guard origin(for: urlString) != nil else { return nil }
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("://") { return trimmed }
    return "https://" + trimmed
  }
}

extension CSecurityCredential {
  /// Builds a credential from validated fields, or returns nil when the
  /// URL has no usable origin or a required field is blank.
  static func make(
    url: String, username: String, password: String, displayName: String? = nil
  ) -> CSecurityCredential? {
    guard let origin = CSecurityCredentialValidation.origin(for: url),
      let normalised = CSecurityCredentialValidation.normalisedURL(for: url),
      !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !password.isEmpty
    else { return nil }
    let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    return CSecurityCredential(
      url: normalised, origin: origin, username: username, password: password,
      displayName: name?.isEmpty == false ? name : nil)
  }

  /// Strict origin matching. A credential for google.com is never offered
  /// on google.example.com, google-login.example, or any lookalike: those
  /// are different origins, full stop. There is no suffix matching and no
  /// identity-provider redirect exception in this matcher; a redirect that
  /// legitimately needs another origin needs its own saved credential.
  static func matches(_ credential: CSecurityCredential, pageURL: URL) -> Bool {
    guard let pageOrigin = CredentialPage.origin(pageURL) else { return false }
    return credential.origin == pageOrigin
  }

  static func matches(_ metadata: Metadata, pageURL: URL) -> Bool {
    guard let pageOrigin = CredentialPage.origin(pageURL) else { return false }
    return metadata.origin == pageOrigin
  }
}

// Migration from Comet's older, user-consented import path. The Chromium
// profile store is not silently copied into Security: its records are
// encrypted under that browser's Safe Storage key and belong to a profile
// the user selects at import time (see ImportFeature / LoginsReader).
// The supported, user-controlled migration is: export a CSV from the
// profile store (chrome://password-manager/passwords) or from another
// manager, then import it through CSecurityServiceUI. This converter is
// the single place that turns an already-decrypted imported record into
// a Security credential, so no second conversion rule can drift.
enum CSecurityMigration {
  static func credential(from imported: ImportedPassword) -> CSecurityCredential? {
    CSecurityCredential.make(url: imported.url, username: imported.username, password: imported.password)
  }
}
