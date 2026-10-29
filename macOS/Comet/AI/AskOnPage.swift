import ComposableArchitecture
import Foundation

struct AskTurn: Equatable, Sendable, Identifiable {
  let id: UUID
  var question: String
  var answer: String
  var isStreaming: Bool
  var error: String?
  var grounding: Grounding

  enum Grounding: Equatable, Sendable {
    case page
    case mixed
    case unknown
    case unavailable
  }
}

@Reducer
struct AskOnPageFeature {
  @ObservableState
  struct State: Equatable {
    var tab: Tab.ID
    var url: URL
    var title: String
    var question = ""
    var turns: IdentifiedArrayOf<AskTurn> = []
    var context: PageContext?
    var isReading = false
    var readError: String?
    var isIncognito = false
  }

  enum Action {
    case appeared
    case contextLoaded(PageContext?)
    case questionChanged(String)
    case submit
    case delta(AskTurn.ID, String)
    case finished(AskTurn.ID, Result<String, AIFailure>)
    case cancel
    case clear
    case close
  }

  @Dependency(\.ai) var ai
  @Dependency(\.dismiss) var dismiss
  @Dependency(\.pageContext) var pageContext
  @Dependency(\.uuid) var uuid
  private enum CancelID { case ask }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared:
        state.isReading = true
        state.readError = nil
        return .run { [tab = state.tab, url = state.url, title = state.title] send in
          await send(.contextLoaded(await pageContext.extract(tab, url, title)))
        }

      case let .contextLoaded(context):
        state.isReading = false
        state.context = context
        if context?.isReadable != true {
          state.readError = "This page’s text could not be read. Ask a shorter question, or open a page with readable content."
        }
        return .none

      case let .questionChanged(question):
        state.question = question
        return .none

      case .submit:
        let question = state.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !state.turns.contains(where: \.isStreaming) else { return .none }
        guard AIFeatureGate.isEnabled(.askOnPage) else {
          let id = uuid()
          state.turns.append(
            AskTurn(id: id, question: question, answer: "", isStreaming: false, error: AIFailure.disabled.message, grounding: .unavailable))
          return .none
        }
        guard let context = state.context, context.isReadable else {
          let id = uuid()
          state.turns.append(
            AskTurn(
              id: id, question: question, answer: "", isStreaming: false, error: state.readError,
              grounding: .unavailable))
          return .none
        }
        let id = uuid()
        state.turns.append(AskTurn(id: id, question: question, answer: "", isStreaming: true, error: nil, grounding: .page))
        state.question = ""
        let history = state.turns.dropLast().suffix(4).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n")
        let request = AIRequest.make(
          feature: .askOnPage,
          system: AIGuard.defaultSystem + """
             Answer only from the current page. Label statements that are on the page, inferences from it, or that need research elsewhere. \
            When you refer to a section, use an exact heading from the list. Do not fabricate quotations or heading names. \
            If the page does not contain the answer, say so and suggest a web search.
            """,
          prompt: """
            \(context.promptBlock())

            Previous questions on this same page:
            \(history.isEmpty ? "(none)" : history)

            Question: \(question)
            """,
          provenance: "ask:\(state.tab.uuidString.prefix(8))",
          maxTokens: 500,
          timeout: .seconds(45))
        return .run { send in
          var assembled = ""
          do {
            for try await delta in ai.stream(request) {
              assembled += delta
              await send(.delta(id, assembled))
            }
            await send(.finished(id, .success(assembled)))
          } catch let failure as AIFailure {
            await send(.finished(id, .failure(failure)))
          } catch is CancellationError {
            await send(.finished(id, .failure(.cancelled)))
          } catch {
            await send(.finished(id, .failure(.network(error.localizedDescription))))
          }
        }
        .cancellable(id: CancelID.ask, cancelInFlight: true)

      case let .delta(id, text):
        state.turns[id: id]?.answer = text
        return .none

      case let .finished(id, result):
        guard var turn = state.turns[id: id] else { return .none }
        turn.isStreaming = false
        switch result {
        case let .success(text):
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          turn.answer = trimmed
          if trimmed.isEmpty { turn.error = AIFailure.empty.message }
          turn.grounding = Self.grounding(trimmed, headings: state.context?.headings ?? [])
        case let .failure(failure):
          if failure != .cancelled || turn.answer.isEmpty {
            turn.error = failure.message
          }
          if failure == .cancelled, !turn.answer.isEmpty {
            turn.answer += "\n\n(Stopped)"
          }
        }
        state.turns[id: id] = turn
        return .none

      case .cancel:
        return .cancel(id: CancelID.ask)

      case .clear:
        state.turns = []
        return .cancel(id: CancelID.ask)

      case .close:
        return .merge(.cancel(id: CancelID.ask), .run { _ in await dismiss() })
      }
    }
  }

  static func grounding(_ answer: String, headings: [PageContext.Heading]) -> AskTurn.Grounding {
    let lower = answer.lowercased()
    if lower.contains("not in the page") || lower.contains("could not be read") || lower.contains("need")
      && lower.contains("search")
    {
      return .mixed
    }
    if headings.contains(where: { answer.contains($0.text) }) { return .page }
    return .page
  }
}
