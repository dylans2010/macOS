import Foundation

enum AIApple {
  static var isAvailable: Bool {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return AppleIntelligenceSession.isAvailable
      }
    #endif
    return false
  }

  static func complete(_ request: AIRequest) async throws -> AIResponse {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return try await AppleIntelligenceSession.complete(request)
      }
    #endif
    throw AIFailure.unsupportedProvider
  }
}

#if canImport(FoundationModels)
  import FoundationModels

  @available(macOS 26.0, *)
  enum AppleIntelligenceSession {
    static var isAvailable: Bool {
      if case .available = SystemLanguageModel.default.availability { return true }
      return false
    }

    static func complete(_ request: AIRequest) async throws -> AIResponse {
      guard isAvailable else { throw AIFailure.unsupportedProvider }
      let session = LanguageModelSession(instructions: Instructions(request.system))
      let response = try await session.respond(to: request.prompt)
      let text = String(describing: response.content).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw AIFailure.empty }
      return AIResponse(text: text, provider: .apple, model: "system")
    }
  }
#endif
