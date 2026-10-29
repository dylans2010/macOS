import ComposableArchitecture
import Foundation
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Comet", category: "AI")

struct AIClient: Sendable {
  var complete: @Sendable (AIRequest) async throws -> AIResponse
  var stream: @Sendable (AIRequest) -> AsyncThrowingStream<String, Error>
  var isConfigured: @Sendable () -> Bool
}

extension AIClient: TestDependencyKey {
  static let testValue = AIClient(
    complete: { _ in throw AIFailure.disabled },
    stream: { _ in AsyncThrowingStream { $0.finish(throwing: AIFailure.disabled) } },
    isConfigured: { false }
  )
}

extension DependencyValues {
  var ai: AIClient {
    get { self[AIClient.self] }
    set { self[AIClient.self] = newValue }
  }
}

extension AIClient: DependencyKey {
  static let liveValue = AIClient(
    complete: { try await AIRuntime.shared.complete($0) },
    stream: { AIRuntime.shared.stream($0) },
    isConfigured: { AIRuntime.isConfigured(AIFeatureGate.current) }
  )
}

actor AIRuntime {
  static let shared = AIRuntime()
  private let transport: AIHTTPTransport
  let session = AISession()

  func clearCache() async {
    await session.clearCache()
  }

  init(transport: AIHTTPTransport = .live) {
    self.transport = transport
  }

  static func isConfigured(_ settings: AISettings) -> Bool {
    guard settings.provider.isAvailable else { return false }
    switch settings.provider {
    case .apple: return AIApple.isAvailable
    case .ollama: return settings.resolvedBaseURL.map { EndpointPolicy.allows($0, allowInsecureHTTP: true) } ?? false
    case .openai, .anthropic, .gemini:
      return AICredentials.load(settings.provider) != nil
    case .custom:
      return settings.resolvedBaseURL.map { EndpointPolicy.allows($0, allowInsecureHTTP: settings.allowInsecureHTTP) } ?? false
    }
  }

  func complete(_ request: AIRequest) async throws -> AIResponse {
    let settings = await MainActor.run { AIFeatureGate.current }
    try Self.preflight(request.feature, settings)
    return try await session.run(request) {
      try await self.send(request, settings: settings)
    }
  }

  nonisolated func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let settings = await MainActor.run { AIFeatureGate.current }
          try Self.preflight(request.feature, settings)
          try await self.emit(request, settings: settings, into: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func preflight(_ feature: AIFeatureID, _ settings: AISettings) throws {
    guard settings.isOn(feature) else { throw AIFailure.disabled }
    guard feature.usesProvider else { throw AIFailure.unsupportedProvider }
    guard isConfigured(settings) else {
      throw AIFailure.notConfigured(settings.provider.needsAPIKey
        ? "Add an API key for \(settings.provider.title) in Settings → AI Features."
        : "\(settings.provider.title) is not available. Check Settings → AI Features.")
    }
  }

  private func send(_ request: AIRequest, settings: AISettings) async throws -> AIResponse {
    let request = SensitiveText.redacted(request)
    if settings.provider == .apple {
      return try await withTimeout(request.timeout) { try await AIApple.complete(request) }
    }
    let http = try makeHTTP(request, settings: settings, stream: false)
    log.info("AI \(request.feature.rawValue, privacy: .public) via \(settings.provider.rawValue, privacy: .public) \(request.provenance, privacy: .public)")
    return try await withTimeout(request.timeout) {
      let (data, response) = try await self.transport.data(http)
      try Task.checkCancellation()
      try AIHTTP.check(data, response)
      switch settings.provider {
      case .anthropic: return try AnthropicAPI.parse(data, settings: settings)
      case .gemini: return try GeminiAPI.parse(data, settings: settings)
      case .openai, .ollama, .custom: return try OpenAICompatible.parse(data, settings: settings)
      case .apple: throw AIFailure.unsupportedProvider
      }
    }
  }

  private func emit(
    _ request: AIRequest, settings: AISettings, into continuation: AsyncThrowingStream<String, Error>.Continuation
  ) async throws {
    if settings.provider == .apple || settings.provider == .gemini {
      let response = try await send(request, settings: settings)
      continuation.yield(response.text)
      return
    }
    let http = try makeHTTP(request, settings: settings, stream: true)
    try await withTimeout(request.timeout) {
      let (bytes, response) = try await self.transport.bytes(http)
      if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
        var collected = Data()
        for try await byte in bytes {
          collected.append(byte)
          if collected.count > 8_192 { break }
        }
        try AIHTTP.check(collected, response)
      }
      var buffer = ""
      for try await byte in bytes {
        try Task.checkCancellation()
        buffer.append(Character(UnicodeScalar(byte)))
        while let range = buffer.range(of: "\n") {
          let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
          buffer.removeSubrange(..<range.upperBound)
          let delta =
            settings.provider == .anthropic
            ? AnthropicAPI.delta(fromSSE: line) : OpenAICompatible.delta(fromSSE: line)
          if let delta, !delta.isEmpty { continuation.yield(delta) }
        }
      }
    }
  }

  private func makeHTTP(_ request: AIRequest, settings: AISettings, stream: Bool) throws -> URLRequest {
    if let base = settings.resolvedBaseURL, !EndpointPolicy.allows(base, allowInsecureHTTP: settings.allowInsecureHTTP || settings.provider == .ollama) {
      throw AIFailure.notConfigured(EndpointPolicy.warning(for: base.absoluteString) ?? "This endpoint is not allowed.")
    }
    let key = AICredentials.load(settings.provider)
    switch settings.provider {
    case .anthropic:
      guard let key else { throw AIFailure.notConfigured("Add an Anthropic API key in Settings → AI Features.") }
      return try AnthropicAPI.request(request, settings: settings, key: key, stream: stream)
    case .gemini:
      guard let key else { throw AIFailure.notConfigured("Add a Gemini API key in Settings → AI Features.") }
      return try GeminiAPI.request(request, settings: settings, key: key)
    case .openai:
      guard let key else { throw AIFailure.notConfigured("Add an OpenAI API key in Settings → AI Features.") }
      return try OpenAICompatible.request(request, settings: settings, key: key, stream: stream)
    case .ollama, .custom:
      return try OpenAICompatible.request(request, settings: settings, key: key, stream: stream)
    case .apple:
      throw AIFailure.unsupportedProvider
    }
  }
}

func withTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await work() }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw AIFailure.timeout
    }
    guard let result = try await group.next() else { throw AIFailure.cancelled }
    group.cancelAll()
    return result
  }
}
