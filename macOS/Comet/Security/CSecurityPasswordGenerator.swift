import Foundation
import Security

// Password generation for Security. Cryptographically secure randomness
// only: SecRandomCopyBytes. Never random(), never a timestamp, never an
// AI-generated string.
//
// Character sets are explicit and documented. Ambiguous characters
// (0/O, 1/l/I) are NOT removed: removing them would shrink the sets and
// complicate the class guarantees for short passwords, and a generated
// password is copied, not retyped, in the normal flow.
//
// Length policy (spec): the user-configurable default must stay inside
// 8...12. The generator itself accepts any length >= 4 (one character
// per required class); the service clamps the configured length to
// 8...12 so a stored preference outside that range can never produce
// a shorter or longer default. Expanding the range later means changing
// CSecurityGenerationSettings.allowedRange in one place.
enum CSecurityPasswordGenerator {
  static let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  static let lowercase = "abcdefghijklmnopqrstuvwxyz"
  static let digits = "0123456789"
  static let symbols = "!@#$%^&*()-_=+[]{};:,.<>?"
  static let all = uppercase + lowercase + digits + symbols

  /// Settings the user can change in Security settings. Stored in
  /// UserDefaults (non-secret: a length is not a credential).
  struct Settings: Equatable, Sendable {
    /// Clamped to 8...12 on init and on decode.
    var length: Int
    static let allowedRange = 8...12
    static let `default` = Settings(length: 12)

    init(length: Int) {
      self.length = min(Self.allowedRange.upperBound, max(Self.allowedRange.lowerBound, length))
    }
  }

  enum GenerationError: Error, Sendable {
    case randomSourceFailed
    case lengthTooShort
  }

  /// Generates a password of `length` characters containing at least one
  /// uppercase letter, one lowercase letter, one digit, and one symbol.
  /// Selection is unbiased: each random value is rejection-sampled into
  /// its set's range instead of using modulo, which would bias the first
  /// (256 % count) characters. Required-class characters are placed at
  /// random positions, then the whole password is shuffled with the same
  /// secure source, so the class positions do not leak structure.
  static func generate(length: Int) throws -> String {
    guard length >= 4 else { throw GenerationError.lengthTooShort }
    var chars: [Character] = []
    chars.append(try secureCharacter(from: uppercase))
    chars.append(try secureCharacter(from: lowercase))
    chars.append(try secureCharacter(from: digits))
    chars.append(try secureCharacter(from: symbols))
    while chars.count < length {
      chars.append(try secureCharacter(from: all))
    }
    // Fisher-Yates with secure indices.
    if chars.count > 1 {
      for i in stride(from: chars.count - 1, through: 1, by: -1) {
        let j = try secureIndex(upperBound: i + 1)
        chars.swapAt(i, j)
      }
    }
    return String(chars)
  }

  /// The configured-length convenience: clamps through Settings so the
  /// 8...12 contract holds even for a stale or hand-edited preference.
  static func generate(settings: Settings) throws -> String {
    try generate(length: settings.length)
  }

  /// Pure validation used by tests and by the UI before a generated
  /// password is ever offered: length plus all four classes.
  static func satisfiesPolicy(_ password: String, lengthRange: ClosedRange<Int> = 8...12) -> Bool {
    guard lengthRange.contains(password.count) else { return false }
    return password.contains { $0.isUppercase }
      && password.contains { $0.isLowercase }
      && password.contains { $0.isNumber }
      && password.contains { symbols.contains($0) }
  }

  // MARK: - Secure randomness

  private static func secureBytes(count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else { throw GenerationError.randomSourceFailed }
    return bytes
  }

  /// Unbiased index in 0..<upperBound via rejection sampling.
  private static func secureIndex(upperBound: Int) throws -> Int {
    precondition(upperBound > 0)
    // Largest multiple of upperBound that fits in a byte, minus one.
    let limit = 256 - (256 % upperBound)
    while true {
      let byte = try secureBytes(count: 1)[0]
      if Int(byte) < limit { return Int(byte) % upperBound }
    }
  }

  private static func secureCharacter(from set: String) throws -> Character {
    let characters = Array(set)
    return characters[try secureIndex(upperBound: characters.count)]
  }
}
