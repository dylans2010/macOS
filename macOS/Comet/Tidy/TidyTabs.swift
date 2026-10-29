import ComposableArchitecture
import Foundation

extension TabsFeature {
  // Tidy: the Today tabs sorted into named groups, on the Mac, while the broom sweeps once.
  @CasePathable
  enum Tidy {
    case start
    case swept
    case proposed(TidyPreview)
    case apply
    case cancel
  }

  // Tidy shows once Today has six tabs to sort.
  static let tidyMinimum = 6
  static let sweep = Duration.milliseconds(600)

  func tidy(_ state: inout State, _ action: Action) -> Effect<Action> {
    switch action {
    case .tidy(.start):
      guard !state.isTidying else { return .none }
      state.tidyPreview = nil
      let candidates = state.tidyCandidates.map(TidyTab.init)
      guard !candidates.isEmpty else {
        return .send(.delegate(.tidyMessage("No tab groups found")))
      }
      state.isTidying = true
      if AIFeatureGate.isEnabled(.tidyTabs) {
        return .run { [candidates] send in
          let local = TidyProposal.local(candidates)
          do {
            @Dependency(\.ai) var ai
            let response = try await ai.complete(TidyProposal.request(candidates))
            let preview = TidyProposal.parse(response.text, tabs: candidates) ?? local
            await send(.tidy(.proposed(preview)))
          } catch {
            await send(.tidy(.proposed(local)))
          }
        }
      }
      return apply(TidyProposal.local(candidates), &state)

    case let .tidy(.proposed(preview)):
      state.isTidying = false
      if preview.isAI {
        state.tidyPreview = preview
        return preview.groups.isEmpty ? .send(.delegate(.tidyMessage("No tab groups found"))) : .none
      }
      return apply(preview, &state)

    case .tidy(.apply):
      guard let preview = state.tidyPreview else { return .none }
      state.tidyPreview = nil
      return apply(preview, &state)

    case .tidy(.cancel):
      state.tidyPreview = nil
      state.isTidying = false
      return .none

    case .tidy(.swept):
      state.isTidying = false
      return .none

    default:
      return .none
    }
  }

  private func apply(_ preview: TidyPreview, _ state: inout State) -> Effect<Action> {
    state.isTidying = true
    state.tidyPreview = nil
    let layout = TabLayout(state)
    let candidates = Set(state.tidyCandidates.map(\.id))
    for group in preview.groups {
      let ids = group.tabIDs.filter(candidates.contains)
      guard ids.count >= 2 else { continue }
      let made = TabGroup(id: uuid(), name: group.name, color: state.nextGroupColor)
      state.groups.append(made)
      for id in ids {
        state.ownTabs[id: id]?.groupID = made.id
      }
    }
    let found = TabLayout(state) != layout
    return .merge(
      .send(.delegate(found ? .moved(layout) : .tidyMessage("No tab groups found"))),
      .run { send in
        try await clock.sleep(for: Self.sweep)
        await send(.tidy(.swept))
      })
  }
}

extension TabsFeature.State {
  // The Today tabs Tidy sorts: those in no group, and not in a split, whose panes stay together.
  var tidyCandidates: [Tab] {
    tabs(in: .unpinned).filter { $0.groupID == nil && split(of: $0.id) == nil }
  }
}

extension TidyTab {
  init(_ tab: Tab) {
    self.init(id: tab.id, title: tab.displayTitle, host: tab.url.host() ?? "")
  }
}
