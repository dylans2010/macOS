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

// Optional provider headers. Values can be secrets, so they stay in the Keychain and never in AISettings.json.
enum AIExtraHeaders {
  static func service(_ kind: AIProviderKind) -> String {
    "\(Bundle.main.bundleIdentifier ?? "comet").ai-extra-headers.\(kind.rawValue)"
  }

  static func allowed(_ name: String) -> Bool {
    let lowered = name.lowercased()
    let banned: Set<String> = ["cookie", "host", "content-length", "transfer-encoding", "connection", "proxy-authorization"]
    guard !name.isEmpty, !banned.contains(lowered) else { return false }
    return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
  }

  static func parse(_ text: String) -> [String: String] {
    var headers: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard allowed(String(name)), !value.isEmpty, !value.contains("\r") else { continue }
      headers[String(name)] = String(value)
    }
    return headers
  }

  static func load(_ kind: AIProviderKind) -> [String: String] {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service(kind),
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return [:] }
    return json.filter { allowed($0.key) && !$0.value.isEmpty }
  }

  @discardableResult
  static func save(_ kind: AIProviderKind, headers: [String: String]) -> OSStatus {
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service(kind)] as CFDictionary)
    let clean = headers.filter { allowed($0.key) && !$0.value.isEmpty && !$0.value.contains("\n") && !$0.value.contains("\r") }
    guard !clean.isEmpty, let data = try? JSONSerialization.data(withJSONObject: clean) else { return errSecSuccess }
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service(kind),
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    return SecItemAdd(query as CFDictionary, nil)
  }

  static func apply(_ headers: [String: String], to request: inout URLRequest) {
    for (name, value) in headers where allowed(name) && !value.isEmpty && !value.contains("\n") && !value.contains("\r") {
      request.setValue(value, forHTTPHeaderField: name)
    }
  }
}
