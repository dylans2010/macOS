import Foundation

// In-flight deduplication, a bounded summary cache, and stale-result rejection. Cached values are keyed by
// destination or prompt identity, never stored with the raw page body on disk.
actor AISession {
  private var inflight: [String: Task<AIResponse, Error>] = [:]
  private var cache: [String: Entry] = [:]
  private var order: [String] = []
  static let limit = 200
  static let ttl: TimeInterval = 60 * 60

  private struct Entry {
    var response: AIResponse
    var created: Date
  }

  func run(_ request: AIRequest, perform: @escaping @Sendable () async throws -> AIResponse) async throws -> AIResponse {
    do {
      return try await execute(request, perform: perform)
    } catch is CancellationError {
      throw AIFailure.cancelled
    }
  }

  private func execute(_ request: AIRequest, perform: @escaping @Sendable () async throws -> AIResponse) async throws
    -> AIResponse
  {
    try Task.checkCancellation()
    let key = request.cacheKey
    if let key, let cached = cache[key], Date().timeIntervalSince(cached.created) < Self.ttl {
      return cached.response
    }
    if let key, let existing = inflight[key] {
      let response = try await existing.value
      try Task.checkCancellation()
      return response
    }
    let task = Task { try await perform() }
    if let key { inflight[key] = task }
    do {
      let response = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try Task.checkCancellation()
      if let key { store(key, response) }
      if let key { inflight[key] = nil }
      return response
    } catch is CancellationError {
      if let key { inflight[key] = nil }
      throw AIFailure.cancelled
    } catch let failure as AIFailure {
      if let key { inflight[key] = nil }
      throw failure
    } catch {
      if let key { inflight[key] = nil }
      throw AIFailure.network(error.localizedDescription)
    }
  }

  func clearCache() {
    cache = [:]
    order = []
  }

  private func store(_ key: String, _ response: AIResponse) {
    if cache[key] == nil { order.append(key) }
    cache[key] = Entry(response: response, created: Date())
    while order.count > Self.limit, let oldest = order.first {
      order.removeFirst()
      cache[oldest] = nil
    }
  }
}

extension AIClient {
  static let session = AIRuntime.shared
}
