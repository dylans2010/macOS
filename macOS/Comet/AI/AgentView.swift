import SwiftUI

struct AgentPanel: View {
  @Bindable private var activity = AgentActivity.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Agent").font(.system(size: 13, weight: .semibold))
          Text(activity.phase.label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Stop", action: activity.stop).disabled(!activity.isEngaged)
        Button(activity.phase == .paused ? "Resume" : "Pause", action: { activity.phase == .paused ? activity.resume() : activity.pause() })
          .disabled(!activity.isEngaged && activity.phase != .paused)
        Button("Take Over", action: activity.takeOver).disabled(!activity.isEngaged)
        Button { activity.close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
      }
      Text(activity.title.isEmpty ? "No page" : activity.title).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
      if !activity.detail.isEmpty {
        Text(activity.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(activity.messages) { message in
            Text(message.text)
              .font(.system(size: 12))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
              .background(message.role == "user" ? Color.white.opacity(0.08) : Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
      .frame(maxHeight: 220)
      if let pending = activity.pending {
        VStack(alignment: .leading, spacing: 4) {
          Text("Approve \(pending.name)?").font(.system(size: 12, weight: .semibold))
          Text(pending.arguments.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced)).lineLimit(4)
          HStack {
            Button("Approve", action: activity.approve)
            Button("Don’t allow", action: activity.deny)
          }
        }
        .padding(8)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
      }
      TextField("Ask Agent to work on this page", text: $activity.draft, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(2...4)
        .onSubmit(activity.submit)
      HStack {
        Button("Send", action: activity.submit).disabled(activity.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activity.isEngaged)
        Button("Clear", action: activity.clear)
        Spacer()
        Text("Page content is sent only while Agent is enabled.").font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(width: 360)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
  }
}

struct AgentStatusChip: View {
  @Bindable private var activity = AgentActivity.shared

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "sparkles")
      Text(activity.phase.label).font(.system(size: 12, weight: .medium))
      Button("Pause") { activity.pause() }.buttonStyle(.borderless).font(.system(size: 11))
      Button("Stop") { activity.stop() }.buttonStyle(.borderless).font(.system(size: 11))
      Button("Take Over") { activity.takeOver() }.buttonStyle(.borderless).font(.system(size: 11))
      Button("Open") { activity.isOpen = true }.buttonStyle(.borderless).font(.system(size: 11))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Agent \(activity.phase.label)")
  }
}
