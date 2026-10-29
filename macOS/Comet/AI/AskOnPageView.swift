import ComposableArchitecture
import SwiftUI

struct AskOnPageView: View {
  @Bindable var store: StoreOf<AskOnPageFeature>
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "text.bubble").font(.system(size: 12, weight: .semibold))
        Text("Ask on Page").font(.system(size: 12, weight: .semibold))
        Text(store.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        Spacer()
        if store.turns.contains(where: \.isStreaming) {
          Button("Stop") { store.send(.cancel) }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
        }
        Button("Clear") { store.send(.clear) }
          .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
          .disabled(store.turns.isEmpty)
        Button { store.send(.close) } label: {
          Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
      }
      .foregroundStyle(.white)

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if store.isReading {
            Text("Reading this page…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
          } else if let error = store.readError, store.turns.isEmpty {
            Text(error).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
          }
          ForEach(store.turns) { turn in
            VStack(alignment: .leading, spacing: 4) {
              Text(turn.question).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
              if let error = turn.error, turn.answer.isEmpty {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.notFound)
              } else {
                Text(turn.answer.isEmpty && turn.isStreaming ? "…" : turn.answer)
                  .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
                  .textSelection(.enabled)
                if !turn.isStreaming, turn.grounding != .unavailable {
                  Text(label(turn.grounding))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                }
              }
            }
          }
        }
      }
      .frame(maxHeight: 220)

      HStack(spacing: 8) {
        TextField(
          "", text: $store.question.sending(\.questionChanged),
          prompt: Text("Ask about this page").foregroundStyle(Theme.CommandBar.placeholder)
        )
        .textFieldStyle(.plain)
        .focused($isFocused)
        .onSubmit { store.send(.submit) }
        .onExitCommand { store.send(.close) }
        Button("Ask") { store.send(.submit) }
          .buttonStyle(.plain)
          .font(.system(size: 12, weight: .semibold))
          .disabled(store.question.trimmingCharacters(in: .whitespaces).isEmpty || store.turns.contains(where: \.isStreaming))
      }
      .font(.system(size: 13))
      .foregroundStyle(.white)
    }
    .padding(12)
    .frame(width: 380)
    .background(Theme.findBar, in: RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.55), radius: 10, y: 5)
    .onAppear {
      isFocused = true
      store.send(.appeared)
    }
  }

  private func label(_ grounding: AskTurn.Grounding) -> String {
    switch grounding {
    case .page: "Grounded in this page. Processed by the configured AI provider."
    case .mixed: "Partly inferred, or needs a source beyond this page."
    case .unknown: "Processed by the configured AI provider."
    case .unavailable: ""
    }
  }
}
