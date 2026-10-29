import Foundation

struct TidyPreview: Equatable, Sendable {
  var groups: [TidyGroup]
  var ungrouped: [Tab.ID]
  var isAI: Bool
}

enum TidyProposal {
  static func request(_ tabs: [TidyTab]) -> AIRequest {
    let listing = tabs.enumerated().map { index, tab in
      "\(index + 1). id=\(tab.id.uuidString) title=\(tab.title) host=\(tab.host)"
    }.joined(separator: "\n")
    return AIRequest.make(
      feature: .tidyTabs,
      system: AIGuard.defaultSystem + """
         Group related browser tabs. Reply with JSON only: {"groups":[{"name":"…","ids":["uuid",…]}],"ungrouped":["uuid",…)}. \
        Use only the supplied ids. Do not invent tabs. Names should be short. Leave a tab ungrouped rather than forcing it. \
        Prefer topics such as research, development, documentation, shopping, news, entertainment, or a project name when they fit.
        """,
      prompt: AIGuard.wrapUntrusted(listing, label: "tab list"),
      provenance: "tidy:\(tabs.count)",
      maxTokens: 500,
      timeout: .seconds(20))
  }

  static func parse(_ text: String, tabs: [TidyTab]) -> TidyPreview? {
    let jsonText = extractJSON(text)
    guard let data = jsonText.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let known = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
    var used: Set<Tab.ID> = []
    var groups: [TidyGroup] = []
    let rawGroups = json["groups"] as? [[String: Any]] ?? []
    for raw in rawGroups {
      let name = ((raw["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let ids = (raw["ids"] as? [String] ?? []).compactMap { UUID(uuidString: $0) }
        .filter { known[$0] != nil && used.insert($0).inserted }
      guard !name.isEmpty, ids.count >= 2 else { continue }
      groups.append(TidyGroup(name: String(name.prefix(40)), tabIDs: ids))
    }
    let listed = (json["ungrouped"] as? [String] ?? []).compactMap { UUID(uuidString: $0) }
    var ungrouped = listed.filter { known[$0] != nil && used.insert($0).inserted }
    for tab in tabs where !used.contains(tab.id) {
      ungrouped.append(tab.id)
    }
    guard !groups.isEmpty else { return nil }
    return TidyPreview(groups: groups, ungrouped: ungrouped, isAI: true)
  }

  static func local(_ tabs: [TidyTab]) -> TidyPreview {
    let groups = sortIntoGroups(tabs)
    let grouped = Set(groups.flatMap(\.tabIDs))
    return TidyPreview(groups: groups, ungrouped: tabs.map(\.id).filter { !grouped.contains($0) }, isAI: false)
  }

  private static func extractJSON(_ text: String) -> String {
    if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
      return String(text[start...end])
    }
    return text
  }
}
