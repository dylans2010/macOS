import ComposableArchitecture
import Foundation

// The AI browsing features, each independently switchable. The master switch is the gate for anything that
// sends page content or a prompt to a provider; Instant Links is search navigation and does not need it.
enum AIFeatureID: String, CaseIterable, Codable, Sendable {
  case linkPreviews
  case askOnPage
  case tidyTabs
  case tidyTabTitles
  case tidyDownloads
  case commandBarAsk
  case instantLinks
  case agent

  var title: String {
    switch self {
    case .linkPreviews: "Link Previews"
    case .askOnPage: "Ask on Page"
    case .tidyTabs: "Organize Tabs"
    case .tidyTabTitles: "Pinned Tab Titles"
    case .tidyDownloads: "Download Names"
    case .commandBarAsk: "Ask in Command Bar"
    case .instantLinks: "Instant Links"
    case .agent: "Agent"
    }
  }

  var summary: String {
    switch self {
    case .linkPreviews:
      "Hold Shift over a link to read a short summary of the destination before you open it."
    case .askOnPage:
      "Ask a question about the page you are on. Answers stay grounded in that page’s readable text."
    case .tidyTabs:
      "When you Tidy Today tabs, propose named groups from titles and sites. Local grouping still runs if AI is off."
    case .tidyTabTitles:
      "Shorten long titles on pinned tabs so the sidebar stays readable, without replacing a name you typed."
    case .tidyDownloads:
      "When a download’s name is opaque, suggest a clearer filename from its metadata. The file itself is not rewritten."
    case .commandBarAsk:
      "Type “ask ” or “? ” in the Command Bar to question a provider without opening a chatbot site."
    case .instantLinks:
      "⇧⌘↩ in the Command Bar opens the first eligible search destination instead of a results page."
    case .agent:
      "Inspect the current page and carry out approved actions with the tools Comet actually runs."
    }
  }

  var privacy: String {
    switch self {
    case .linkPreviews:
      "The destination URL and a public fetch of that page are sent to the configured provider. Signed-in pages are not opened as you."
    case .askOnPage:
      "The current page’s title, URL and readable text are sent to the configured provider. Passwords and form fields are left out."
    case .tidyTabs:
      "Tab titles, addresses and existing group names are sent. Page bodies are not."
    case .tidyTabTitles:
      "Only the tab’s title and site are sent, never the page body."
    case .tidyDownloads:
      "The original filename, source site, MIME type and any document title already on the file are sent. File bytes are not."
    case .commandBarAsk:
      "The question you type is sent. Open tabs and page content are not, unless you also use Ask on Page."
    case .instantLinks:
      "No prompt is sent. The first result comes from search suggestions or a public instant-answer lookup."
    case .agent:
      "The question, a bounded extract of the current page, and tool results are sent. Cookies, passwords, and API keys are not."
    }
  }

  var shortcut: String {
    switch self {
    case .askOnPage: "⌥⌘A"
    case .commandBarAsk: "ask  or  ?"
    case .instantLinks: "⇧⌘↩"
    case .agent: "⌥⇧A"
    case .linkPreviews: "⇧ hover"
    default: ""
    }
  }

  // Whether this feature sends anything to an inference provider.
  var usesProvider: Bool {
    self != .instantLinks
  }
}

struct AISettings: Equatable, Sendable {
  var isEnabled = false
  var linkPreviews = true
  var askOnPage = true
  var tidyTabs = true
  var tidyTabTitles = true
  var tidyDownloads = true
  var commandBarAsk = true
  var instantLinks = true
  var agent = true
  var confirmAgentActions = true
  /// When true (the default), one "Approve for this chat" covers the
  /// rest of that chat's page-changing actions. When false, every
  /// action asks again, as before. Navigation always asks regardless.
  var approveOncePerChat = true
  var allowInsecureHTTP = false
  var agentSystemPrompt = ""
  var provider = AIProviderKind.openai
  var model = ""
  var baseURL = ""

  func isOn(_ feature: AIFeatureID) -> Bool {
    switch feature {
    case .instantLinks: instantLinks
    case .linkPreviews: isEnabled && linkPreviews
    case .askOnPage: isEnabled && askOnPage
    case .tidyTabs: isEnabled && tidyTabs
    case .tidyTabTitles: isEnabled && tidyTabTitles
    case .tidyDownloads: isEnabled && tidyDownloads
    case .commandBarAsk: isEnabled && commandBarAsk
    case .agent: isEnabled && agent
    }
  }

  mutating func set(_ feature: AIFeatureID, enabled: Bool) {
    switch feature {
    case .linkPreviews: linkPreviews = enabled
    case .askOnPage: askOnPage = enabled
    case .tidyTabs: tidyTabs = enabled
    case .tidyTabTitles: tidyTabTitles = enabled
    case .tidyDownloads: tidyDownloads = enabled
    case .commandBarAsk: commandBarAsk = enabled
    case .instantLinks: instantLinks = enabled
    case .agent: agent = enabled
    }
  }

  var activeAgentPrompt: String {
    let trimmed = agentSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? AgentPrompt.defaultText : trimmed
  }

  var resolvedModel: String {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? provider.defaultModel : trimmed
  }

  var resolvedBaseURL: URL? {
    let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return provider.defaultBaseURL }
    return URL(string: raw)
  }
}

extension AISettings: Codable {
  private enum CodingKeys: String, CodingKey {
    case isEnabled, linkPreviews, askOnPage, tidyTabs, tidyTabTitles, tidyDownloads, commandBarAsk, instantLinks
    case agent, confirmAgentActions, approveOncePerChat, allowInsecureHTTP, agentSystemPrompt, provider, model, baseURL
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    linkPreviews = try container.decodeIfPresent(Bool.self, forKey: .linkPreviews) ?? true
    askOnPage = try container.decodeIfPresent(Bool.self, forKey: .askOnPage) ?? true
    tidyTabs = try container.decodeIfPresent(Bool.self, forKey: .tidyTabs) ?? true
    tidyTabTitles = try container.decodeIfPresent(Bool.self, forKey: .tidyTabTitles) ?? true
    tidyDownloads = try container.decodeIfPresent(Bool.self, forKey: .tidyDownloads) ?? true
    commandBarAsk = try container.decodeIfPresent(Bool.self, forKey: .commandBarAsk) ?? true
    instantLinks = try container.decodeIfPresent(Bool.self, forKey: .instantLinks) ?? true
    agent = try container.decodeIfPresent(Bool.self, forKey: .agent) ?? true
    confirmAgentActions = try container.decodeIfPresent(Bool.self, forKey: .confirmAgentActions) ?? true
    approveOncePerChat = try container.decodeIfPresent(Bool.self, forKey: .approveOncePerChat) ?? true
    allowInsecureHTTP = try container.decodeIfPresent(Bool.self, forKey: .allowInsecureHTTP) ?? false
    agentSystemPrompt = try container.decodeIfPresent(String.self, forKey: .agentSystemPrompt) ?? ""
    provider = try container.decodeIfPresent(AIProviderKind.self, forKey: .provider) ?? .openai
    model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
    baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
  }
}

enum EndpointPolicy {
  static func isLoopback(_ url: URL) -> Bool {
    let host = url.host()?.lowercased()
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  static func allows(_ url: URL, allowInsecureHTTP: Bool) -> Bool {
    switch url.scheme?.lowercased() {
    case "https": true
    case "http": isLoopback(url) || allowInsecureHTTP
    default: false
    }
  }

  static func warning(for raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return "Enter a full URL, including https://." }
    if scheme == "https" || (scheme == "http" && isLoopback(url)) { return nil }
    if scheme == "http" { return "This endpoint is not HTTPS. Page text and the API key can be read on the network unless you allow insecure HTTP." }
    return "Only https endpoints are used. Local http is limited to this Mac."
  }
}

extension SharedKey where Self == FileStorageKey<AISettings>.Default {
  static var aiSettings: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "AISettings.json")), default: AISettings()]
  }
}

enum AIFeatureGate {
  static func isEnabled(_ feature: AIFeatureID, settings: AISettings = current) -> Bool {
    settings.isOn(feature)
  }

  static var current: AISettings {
    @Shared(.aiSettings) var settings
    return settings
  }
}
