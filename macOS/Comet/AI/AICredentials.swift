import Foundation
import Security

// API keys live in the Keychain. They are never written to AISettings, logs, webpage JavaScript, or feature caches.
enum AICredentials {
  static func service(_ kind: AIProviderKind) -> String {
    "\(Bundle.main.bundleIdentifier ?? "comet").ai-api-key.\(kind.rawValue)"
  }

  static func load(_ kind: AIProviderKind) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service(kind),
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
      return nil
    }
    let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return key?.isEmpty == false ? key : nil
  }

  @discardableResult
  static func save(_ kind: AIProviderKind, key: String) -> OSStatus {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    delete(kind)
    guard !trimmed.isEmpty else { return errSecSuccess }
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service(kind),
      kSecValueData: Data(trimmed.utf8),
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    return SecItemAdd(query as CFDictionary, nil)
  }

  @discardableResult
  static func delete(_ kind: AIProviderKind) -> OSStatus {
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service(kind)] as CFDictionary)
  }

  static func hasKey(_ kind: AIProviderKind) -> Bool {
    load(kind) != nil
  }
}
