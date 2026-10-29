import Foundation

struct AIHTTPTransport: Sendable {
  var data: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  var bytes: @Sendable (URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)

  static let live = AIHTTPTransport(
    data: { request in try await AIHTTP.session.data(for: request) },
    bytes: { request in try await AIHTTP.session.bytes(for: request) }
  )
}

enum AIHTTP {
  // Ephemeral: provider calls must not pick up website cookies, and keys stay off disk.
  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 45
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  static func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func errorBody(_ data: Data) -> String {
    if let json = jsonObject(data) {
      if let error = json["error"] as? [String: Any] {
        return (error["message"] as? String) ?? (error["type"] as? String) ?? ""
      }
      if let message = json["message"] as? String { return message }
    }
    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return String(text.prefix(240))
  }

  static func check(_ data: Data, _ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { throw AIFailure.network("The provider returned no HTTP response.") }
    switch http.statusCode {
    case 200..<300:
      return
    case 401, 403:
      throw AIFailure.notConfigured("The provider rejected the credentials.")
    case 429:
      let retry = http.value(forHTTPHeaderField: "Retry-After")
      throw AIFailure.rateLimited(retry)
    default:
      throw AIFailure.http(http.statusCode, errorBody(data))
    }
  }
}

enum OpenAICompatible {
  static func request(_ request: AIRequest, settings: AISettings, key: String?, stream: Bool, headers: [String: String] = [:]) throws -> URLRequest {
    guard let base = settings.resolvedBaseURL else {
      throw AIFailure.notConfigured("Set a base URL for this provider.")
    }
    let url = base.appending(path: "chat/completions")
    var http = URLRequest(url: url)
    http.httpMethod = "POST"
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let key, !key.isEmpty {
      http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    let body: [String: Any] = [
      "model": settings.resolvedModel,
      "temperature": request.temperature,
      "max_tokens": request.maxTokens,
      "stream": stream,
      "messages": [
        ["role": "system", "content": request.system],
        ["role": "user", "content": request.prompt],
      ],
    ]
    http.httpBody = try JSONSerialization.data(withJSONObject: body)
    AIExtraHeaders.apply(headers, to: &http)
    return http
  }

  static func parse(_ data: Data, settings: AISettings) throws -> AIResponse {
    guard let json = AIHTTP.jsonObject(data),
      let choices = json["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let text = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { throw AIFailure.decoding }
    return AIResponse(text: text, provider: settings.provider, model: settings.resolvedModel)
  }

  static func delta(fromSSE line: String) -> String? {
    let prefix = "data:"
    guard line.hasPrefix(prefix) else { return nil }
    let payload = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" { return nil }
    guard let data = payload.data(using: .utf8), let json = AIHTTP.jsonObject(data),
      let choices = json["choices"] as? [[String: Any]],
      let delta = choices.first?["delta"] as? [String: Any]
    else { return nil }
    return delta["content"] as? String
  }
}

enum AnthropicAPI {
  static func request(_ request: AIRequest, settings: AISettings, key: String, stream: Bool, headers: [String: String] = [:]) throws -> URLRequest {
    guard let base = settings.resolvedBaseURL else {
      throw AIFailure.notConfigured("Anthropic’s API URL is missing.")
    }
    var http = URLRequest(url: base.appending(path: "messages"))
    http.httpMethod = "POST"
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.setValue(key, forHTTPHeaderField: "x-api-key")
    http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let body: [String: Any] = [
      "model": settings.resolvedModel,
      "max_tokens": request.maxTokens,
      "temperature": request.temperature,
      "stream": stream,
      "system": request.system,
      "messages": [["role": "user", "content": request.prompt]],
    ]
    http.httpBody = try JSONSerialization.data(withJSONObject: body)
    AIExtraHeaders.apply(headers, to: &http)
    return http
  }

  static func parse(_ data: Data, settings: AISettings) throws -> AIResponse {
    guard let json = AIHTTP.jsonObject(data),
      let content = json["content"] as? [[String: Any]]
    else { throw AIFailure.decoding }
    let text = content.compactMap { block -> String? in
      guard (block["type"] as? String) == "text" else { return nil }
      return block["text"] as? String
    }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw AIFailure.empty }
    return AIResponse(text: text, provider: .anthropic, model: settings.resolvedModel)
  }

  static func delta(fromSSE line: String) -> String? {
    let prefix = "data:"
    guard line.hasPrefix(prefix) else { return nil }
    let payload = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    guard let data = payload.data(using: .utf8), let json = AIHTTP.jsonObject(data),
      (json["type"] as? String) == "content_block_delta",
      let delta = json["delta"] as? [String: Any]
    else { return nil }
    return delta["text"] as? String
  }
}

enum GeminiAPI {
  static func request(_ request: AIRequest, settings: AISettings, key: String, headers: [String: String] = [:]) throws -> URLRequest {
    guard let base = settings.resolvedBaseURL else {
      throw AIFailure.notConfigured("Gemini’s API URL is missing.")
    }
    let model = settings.resolvedModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? settings.resolvedModel
    guard let url = URL(string: "\(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/models/\(model):generateContent")
    else { throw AIFailure.notConfigured("Gemini’s API URL is not valid.") }
    var http = URLRequest(url: url)
    http.httpMethod = "POST"
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    let body: [String: Any] = [
      "systemInstruction": ["parts": [["text": request.system]]],
      "contents": [["role": "user", "parts": [["text": request.prompt]]]],
      "generationConfig": ["maxOutputTokens": request.maxTokens, "temperature": request.temperature],
    ]
    http.httpBody = try JSONSerialization.data(withJSONObject: body)
    AIExtraHeaders.apply(headers, to: &http)
    return http
  }

  static func parse(_ data: Data, settings: AISettings) throws -> AIResponse {
    guard let json = AIHTTP.jsonObject(data),
      let candidates = json["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]]
    else {
      if let json = AIHTTP.jsonObject(data), let error = json["error"] as? [String: Any], let message = error["message"] as? String {
        throw AIFailure.http(400, message)
      }
      throw AIFailure.decoding
    }
    let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw AIFailure.empty }
    return AIResponse(text: text, provider: .gemini, model: settings.resolvedModel)
  }
}

struct DiscoveredModel: Equatable, Sendable, Identifiable {
  var id: String
  var displayName: String
  var provider: String
  var capabilities: [String]
  var capabilitiesKnown: Bool

  var pickerTitle: String {
    displayName == id ? id : "\(displayName) — \(id)"
  }
}

enum ModelDiscovery {
  static func listURL(_ base: URL) -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      return base.appending(path: "models")
    }
    var path = components.path
    if path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix("/chat/completions") {
      path.removeLast("/chat/completions".count)
    }
    if path.hasSuffix("/models") {
      components.path = path
      return components.url ?? base
    }
    components.path = path + "/models"
    return components.url ?? base.appending(path: "models")
  }

  static func makeRequest(settings: AISettings, key: String?, headers: [String: String] = [:]) throws -> URLRequest {
    guard settings.provider != .apple else { throw AIFailure.unsupportedProvider }
    guard let base = settings.resolvedBaseURL else {
      throw AIFailure.notConfigured("Set a base URL before fetching models.")
    }
    guard EndpointPolicy.allows(base, allowInsecureHTTP: settings.allowInsecureHTTP || settings.provider == .ollama) else {
      throw AIFailure.notConfigured(EndpointPolicy.warning(for: base.absoluteString) ?? "This endpoint is not allowed.")
    }
    if settings.provider.needsAPIKey && !settings.provider.allowsEmptyKey && (key == nil || key?.isEmpty == true) {
      throw AIFailure.notConfigured("Add an API key before fetching models.")
    }
    var http = URLRequest(url: listURL(base), timeoutInterval: 20)
    http.httpMethod = "GET"
    http.setValue("application/json", forHTTPHeaderField: "Accept")
    switch settings.provider {
    case .anthropic:
      if let key, !key.isEmpty {
        http.setValue(key, forHTTPHeaderField: "x-api-key")
      }
      http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    case .gemini:
      if let key, !key.isEmpty {
        http.setValue(key, forHTTPHeaderField: "x-goog-api-key")
      }
    default:
      if let key, !key.isEmpty {
        http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      }
    }
    AIExtraHeaders.apply(headers, to: &http)
    return http
  }

  static func parse(_ data: Data, provider: AIProviderKind) throws -> [DiscoveredModel] {
    guard let json = AIHTTP.jsonObject(data) else { throw AIFailure.decoding }
    let models: [DiscoveredModel]
    switch provider {
    case .gemini:
      guard json["models"] is [[String: Any]] else { throw AIFailure.decoding }
      models = gemini(json)
    case .anthropic:
      guard json["data"] is [[String: Any]] else { throw AIFailure.decoding }
      models = anthropic(json)
    case .ollama:
      if json["data"] != nil {
        models = try openAI(json)
      } else if json["models"] is [[String: Any]] {
        models = ollamaNative(json)
      } else {
        throw AIFailure.decoding
      }
    default:
      models = try openAI(json)
    }
    if models.isEmpty { throw AIFailure.empty }
    return models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
  }

  static func fetch(settings: AISettings, key: String?) async throws -> [DiscoveredModel] {
    let headers = AIExtraHeaders.load(settings.provider)
    let http = try makeRequest(settings: settings, key: key, headers: headers)
    do {
      let (data, response) = try await AIHTTP.session.data(for: http)
      try Task.checkCancellation()
      try AIHTTP.check(data, response)
      return try parse(data, provider: settings.provider)
    } catch let error as AIFailure {
      throw error
    } catch is CancellationError {
      throw AIFailure.cancelled
    } catch let error as URLError where error.code == .timedOut {
      throw AIFailure.timeout
    } catch let error as URLError where error.code == .cancelled {
      throw AIFailure.cancelled
    } catch {
      throw AIFailure.network("The model list could not be reached.")
    }
  }

  private static func openAI(_ json: [String: Any]) throws -> [DiscoveredModel] {
    guard let rows = json["data"] as? [[String: Any]] else { throw AIFailure.decoding }
    return rows.compactMap { row in
      guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
      let owner = (row["owned_by"] as? String) ?? ""
      return DiscoveredModel(id: id, displayName: id, provider: owner, capabilities: [], capabilitiesKnown: false)
    }
  }

  private static func anthropic(_ json: [String: Any]) -> [DiscoveredModel] {
    guard let rows = json["data"] as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
      guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
      let name = (row["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return DiscoveredModel(
        id: id, displayName: name?.isEmpty == false ? name! : id, provider: "Anthropic", capabilities: [], capabilitiesKnown: false)
    }
  }

  private static func gemini(_ json: [String: Any]) -> [DiscoveredModel] {
    guard let rows = json["models"] as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
      guard var name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
      if name.hasPrefix("models/") { name.removeFirst("models/".count) }
      guard !name.isEmpty else { return nil }
      let display = (row["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let methods = row["supportedGenerationMethods"] as? [String]
      return DiscoveredModel(
        id: name,
        displayName: display?.isEmpty == false ? display! : name,
        provider: "Google",
        capabilities: methods ?? [],
        capabilitiesKnown: methods != nil)
    }
  }

  private static func ollamaNative(_ json: [String: Any]) -> [DiscoveredModel] {
    guard let rows = json["models"] as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
      guard let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
      return DiscoveredModel(id: name, displayName: name, provider: "Ollama", capabilities: [], capabilitiesKnown: false)
    }
  }
}
