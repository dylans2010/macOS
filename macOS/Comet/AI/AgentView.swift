import ComposableArchitecture
import SwiftUI

struct AgentPanel: View {
  @Bindable private var activity = AgentActivity.shared
  @Shared(.aiSettings) private var settings
  @FocusState private var draftFocused: Bool
  @State private var showsPrompt = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Agent").font(.system(size: 13, weight: .semibold))
          Text(activity.phase.label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button { activity.close() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain)
          .accessibilityLabel("Close Agent")
      }
      Text("\(settings.provider.title) · \(settings.resolvedModel.isEmpty ? "No model" : settings.resolvedModel)")
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .accessibilityLabel("Provider \(settings.provider.title), model \(settings.resolvedModel)")
      Text(activity.title.isEmpty ? "No page in context" : activity.title)
        .font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
      Text(activity.url?.absoluteString ?? "Open Agent from a page to use that tab as context.")
        .font(.system(size: 10)).lineLimit(2).foregroundStyle(.secondary)
        .textSelection(.enabled)
      if !activity.detail.isEmpty {
        Text(activity.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
      }
      HStack(spacing: 6) {
        Button("Stop", action: activity.stop).disabled(!activity.isEngaged)
        Button(activity.phase == .paused ? "Resume" : "Pause", action: { activity.phase == .paused ? activity.resume() : activity.pause() })
          .disabled(!activity.isEngaged && activity.phase != .paused)
        Button("Take Over", action: activity.takeOver).disabled(!activity.isEngaged)
      }
      .buttonStyle(.borderless)
      .font(.system(size: 11))
      .accessibilityElement(children: .contain)
      DisclosureGroup("System prompt", isExpanded: $showsPrompt) {
        ScrollView {
          Text(settings.activeAgentPrompt)
            .font(.system(size: 10, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 120)
      }
      .font(.system(size: 11))
      .accessibilityLabel("System prompt")
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            if activity.messages.isEmpty && activity.liveReply.isEmpty {
              Text("Ask Agent to work on this page. Tools run on this tab only after you approve them.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(activity.messages) { message in
              messageRow(message).id(message.id)
            }
            if !activity.liveReply.isEmpty {
              VStack(alignment: .leading, spacing: 4) {
                Text("Receiving…").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(activity.liveReply)
                  .font(.system(size: 12, design: .monospaced))
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .textSelection(.enabled)
              }
              .padding(8)
              .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
              .id("live")
            }
          }
        }
        .onChange(of: activity.messages.count) { _, _ in
          if let last = activity.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
        }
        .onChange(of: activity.liveReply) { _, reply in
          if !reply.isEmpty { proxy.scrollTo("live", anchor: .bottom) }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if activity.phase == .failed || activity.phase == .cancelled {
        Button("Retry", action: activity.retry).font(.system(size: 12))
      }
      if let pending = activity.pending {
        VStack(alignment: .leading, spacing: 4) {
          Text("Approve \(pending.name)?").font(.system(size: 12, weight: .semibold))
          Text(pending.arguments.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
          HStack {
            Button("Approve", action: activity.approve)
            Button("Don’t allow", action: activity.deny)
          }
        }
        .padding(8)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approve \(pending.name)")
      }
      TextField("Ask Agent to work on this page", text: $activity.draft, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(2...4)
        .focused($draftFocused)
        .onSubmit(activity.submit)
        .accessibilityLabel("Agent message")
      HStack {
        Button("Send", action: activity.submit).disabled(activity.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activity.isEngaged)
        Button("Clear", action: activity.clear)
        Spacer(minLength: 0)
      }
      .font(.system(size: 12))
      Text("Page content is sent only while Agent is enabled. Passwords are not.")
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
    .onAppear { draftFocused = true }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agent sidebar")
  }

  @ViewBuilder private func messageRow(_ message: AgentMessage) -> some View {
    if message.role == "tool" {
      DisclosureGroup {
        Text(message.text)
          .font(.system(size: 11, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      } label: {
        Text(message.text.split(separator: "\n").first.map(String.init) ?? "Tool")
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
      }
      .padding(8)
      .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityLabel("Tool result")
    } else {
      Text(message.text)
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding(8)
        .background(message.role == "user" ? Color.white.opacity(0.08) : Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(message.role == "user" ? "You" : "Agent")
    }
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
