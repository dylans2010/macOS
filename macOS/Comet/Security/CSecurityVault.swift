import CryptoKit
import Foundation
import Security

// The encrypted local vault for Security.
//
// Security model, stated plainly:
// - The vault file holds ONE AES-256-GCM sealed box over a versioned
//   JSON document of credentials. The file never contains a plaintext
//   password, and passwords are never written to UserDefaults, ordinary
//   JSON, SQLite, or logs.
// - The 256-bit vault key is generated with SecRandomCopyBytes and kept
//   in the macOS Keychain as a generic-password item, accessible only
//   while the device is unlocked and only on this device
//   (kSecAttrAccessibleWhenUnlockedThisDeviceOnly, not synchronised).
//   No key or password is hardcoded anywhere in this codebase.
// - There is NO master password in this version, and therefore no
//   password-based recovery: deleting the Keychain item, or losing the
//   Keychain, makes the vault permanently unreadable. The settings UI
//   says exactly that; it never claims recoverability it does not have.
//   (A future master-password mode would need PBKDF2/Argon2 with a
//   unique salt — never a plain hash — and a documented recovery story
//   before it could be offered.)
// - The Secure Enclave does not store password records. Keychain items
//   on Apple Silicon may be protected by hardware, but Comet does not
//   claim an Enclave-backed record store it does not use.
// - Authentication (Touch ID / device password via LocalAuthentication)
//   is enforced by CSecurityService at the credential-access boundary.
//   A Keychain read alone is not the authentication gate: the service
//   refuses to release a password unless its authenticated session is
//   valid, even when the key is available.
//
// Failure model:
// - A damaged vault is NEVER overwritten with an empty vault. Loading a
//   corrupt or undecryptable file throws and leaves the file untouched;
//   a previous good copy (written before the last successful save) is
//   tried once as a fallback. Saving refuses to run until a vault has
//   been loaded successfully, so a failed load cannot turn into an
//   empty save.
// - Writes are atomic (Data.write with .atomic) plus the previous-copy
//   backup, so an interrupted write leaves either the old vault or the
//   new one, not a half-written file.
enum CSecurityVault {
  static let schemaVersion = 1

  enum Error: Swift.Error, Equatable, Sendable {
    case keychainUnavailable
    case keyGenerationFailed
    case vaultCorrupted
    case vaultNotLoaded
    case persistenceFailed
    case credentialNotFound
  }

  // MARK: - Envelope

  struct Envelope: Codable, Sendable {
    var version: Int
    /// AES-GCM sealed box, combined form (nonce + ciphertext + tag),
    /// base64-encoded. The plaintext is a JSON VaultDocument.
    var sealedBox: String
  }

  struct VaultDocument: Codable, Sendable {
    var version: Int
    var credentials: [CSecurityCredential]
  }

  // MARK: - Key storage (injectable for tests)

  protocol KeyStore: Sendable {
    func loadKey() throws -> Data?
    func saveKey(_ key: Data) throws
    func deleteKey() throws
  }

  /// The real Keychain store. One item, one service, one account.
  struct KeychainKeyStore: KeyStore {
    var service: String {
      "\(Bundle.main.bundleIdentifier ?? "com.dylans2010.Comet").security-vault-key"
    }
    var account: String { "vault-key-v1" }

    func loadKey() throws -> Data? {
      let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
        throw Error.keychainUnavailable
      }
      return data
    }

    func saveKey(_ key: Data) throws {
      _ = SecItemDelete([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
      ] as CFDictionary)
      let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecValueData: key,
        kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecAttrSynchronizable: false,
      ]
      guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
        throw Error.keychainUnavailable
      }
    }

    func deleteKey() throws {
      _ = SecItemDelete([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
      ] as CFDictionary)
    }
  }

  /// In-memory key store for tests. Never used by the app target's
  /// default service; tests construct the vault with it explicitly.
  final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private var key: Data?
    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func loadKey() throws -> Data? { locked { key } }
    func saveKey(_ key: Data) throws { locked { self.key = key } }
    func deleteKey() throws { locked { key = nil } }
  }

  // MARK: - File storage (injectable for tests)

  protocol FileStore: Sendable {
    func read() throws -> Data?
    func readBackup() throws -> Data?
    func write(_ data: Data) throws
  }

  /// The real file store: SecurityVault.json beside Comet's other app
  /// data, with SecurityVault.previous.json as the last good copy.
  struct DiskFileStore: FileStore {
    var url: URL { URL.dataDirectory.appending(path: "SecurityVault.json") }
    var backupURL: URL { URL.dataDirectory.appending(path: "SecurityVault.previous.json") }

    func read() throws -> Data? {
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try Data(contentsOf: url)
    }

    func readBackup() throws -> Data? {
      guard FileManager.default.fileExists(atPath: backupURL.path) else { return nil }
      return try Data(contentsOf: backupURL)
    }

    func write(_ data: Data) throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      // Preserve the current vault as the previous good copy BEFORE
      // replacing it, so an interrupted write cannot destroy the only
      // copy. The final write itself is atomic.
      if FileManager.default.fileExists(atPath: url.path) {
        _ = try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: url, to: backupURL)
      }
      try data.write(to: url, options: .atomic)
    }
  }

  /// In-memory file store for tests, with the same previous-copy rule.
  final class MemoryFileStore: FileStore, @unchecked Sendable {
    private var current: Data?
    private var previous: Data?
    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func read() throws -> Data? { locked { current } }
    func readBackup() throws -> Data? { locked { previous } }
    func write(_ data: Data) throws {
      locked {
        if let current { previous = current }
        current = data
      }
    }
    /// Test helper: corrupt the current file without touching the backup.
    func corruptCurrent() { locked { current = Data("not a vault".utf8) } }
  }

  // MARK: - Vault

  /// A loaded vault: its key, its credentials, and whether it was ever
  /// loaded successfully. Only a loaded vault may save.
  final class Store: @unchecked Sendable {
    private let keyStore: any KeyStore
    private let fileStore: any FileStore
    private let lock = NSLock()
    private var _credentials: [CSecurityCredential] = []
    private var _loaded = false
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private var _key: SymmetricKey?

    init(keyStore: any KeyStore, fileStore: any FileStore) {
      self.keyStore = keyStore
      self.fileStore = fileStore
    }

    convenience init() {
      self.init(keyStore: KeychainKeyStore(), fileStore: DiskFileStore())
    }

    var isLoaded: Bool { locked { _loaded } }

    /// Purges the in-memory key and credentials. The encrypted file and
    /// the Keychain key are untouched, so `load()` can reopen the vault
    /// afterwards. This is what the UI's Lock button does.
    func lockVault() {
      locked {
        _key = nil
        _credentials = []
        _loaded = false
      }
    }

    /// Loads (or creates) the vault. First use creates a fresh 256-bit
    /// key in the Keychain and an empty vault. A corrupt vault throws
    /// .vaultCorrupted and is left on disk untouched; the previous good
    /// copy is tried first and, if it decrypts, becomes the vault.
    /// Callers must surface that recovery to the user, not hide it.
    @discardableResult
    func load() throws -> [CSecurityCredential] {
      let key: SymmetricKey
      if let existing = try keyStore.loadKey() {
        key = SymmetricKey(data: existing)
      } else {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else {
          throw Error.keyGenerationFailed
        }
        let data = Data(bytes)
        // Best effort: clear the temporary key bytes from this stack
        // buffer once copied into Data. (Data itself is managed by the
        // Keychain/vault from here on; see SECURITY.md for the limits
        // of in-memory clearing on a managed platform.)
        bytes = [UInt8](repeating: 0, count: 32)
        try keyStore.saveKey(data)
        key = SymmetricKey(data: data)
      }
      let raw = try fileStore.read()
      let credentials: [CSecurityCredential]
      if let raw {
        if let decoded = try? decode(raw, key: key) {
          credentials = decoded
        } else if let backup = try? fileStore.readBackup(), let decoded = try? decode(backup, key: key) {
          credentials = decoded
        } else {
          throw Error.vaultCorrupted
        }
      } else {
        credentials = []
      }
      locked {
        _key = key
        _credentials = credentials
        _loaded = true
      }
      return credentials
    }

    func credentials() throws -> [CSecurityCredential] {
      guard isLoaded else { throw Error.vaultNotLoaded }
      return locked { _credentials }
    }

    /// Persists the given credentials as the new vault contents.
    /// Refuses to run before a successful load, so a failed load can
    /// never be "fixed" by writing an empty vault over the damaged one.
    func save(_ credentials: [CSecurityCredential]) throws {
      guard let key = locked({ _key }), isLoaded else {
        throw Error.vaultNotLoaded
      }
      let document = VaultDocument(version: schemaVersion, credentials: credentials)
      let plaintext = try JSONEncoder().encode(document)
      let sealed = try AES.GCM.seal(plaintext, using: key)
      guard let combined = sealed.combined else { throw Error.persistenceFailed }
      let envelope = Envelope(version: schemaVersion, sealedBox: combined.base64EncodedString())
      let data = try JSONEncoder().encode(envelope)
      do {
        try fileStore.write(data)
      } catch {
        throw Error.persistenceFailed
      }
      locked { _credentials = credentials }
    }

    private func decode(_ raw: Data, key: SymmetricKey) throws -> [CSecurityCredential] {
      let envelope = try JSONDecoder().decode(Envelope.self, from: raw)
      guard envelope.version == schemaVersion,
        let combined = Data(base64Encoded: envelope.sealedBox)
      else { throw Error.vaultCorrupted }
      let sealed = try AES.GCM.SealedBox(combined: combined)
      let plaintext = try AES.GCM.open(sealed, using: key)
      let document = try JSONDecoder().decode(VaultDocument.self, from: plaintext)
      guard document.version == schemaVersion else { throw Error.vaultCorrupted }
      return document.credentials
    }
  }
}
