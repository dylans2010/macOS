import AppKit
import ComposableArchitecture
import SwiftUI

struct LinkPreview: Equatable, Sendable {
  var url: URL
  var title: String
  var domain: String
  var summary: String?
  var points: [String]
  var warning: String?
  var isLoading: Bool

  var destinationLabel: String { title.isEmpty ? domain : title }
}

@MainActor @Observable
final class LinkPreviewController {
  static let shared = LinkPreviewController()
  var preview: LinkPreview?
  private var generation = 0
  private var pending: Task<Void, Never>?
  static let debounce: Duration = .milliseconds(450)

  func hover(_ url: URL?, tab: Tab.ID, shift: Bool) {
    guard shift, let url, PageFetch.isPreviewable(url), AIFeatureGate.isEnabled(.linkPreviews) else {
      cancel()
      return
    }
    if preview?.url == url, preview?.isLoading == false { return }
    pending?.cancel()
    generation += 1
    let id = generation
    let shown = url
    pending = Task {
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled, id == generation, AIFeatureGate.isEnabled(.linkPreviews) else { return }
      guard Engine.shared.hoveredLinks[tab] == shown, NSEvent.modifierFlags.contains(.shift) else { return }
      preview = LinkPreview(
        url: shown, title: "", domain: shown.domain, summary: nil, points: [], warning: nil, isLoading: true)
      await summarize(shown, id: id)
    }
  }

  func cancel() {
    pending?.cancel()
    pending = nil
    generation += 1
    preview = nil
  }

  private func summarize(_ url: URL, id: Int) async {
    do {
      let page = try await PageFetch.fetch(url)
      guard id == generation else { return }
      preview?.title = page.title
      preview?.domain = url.domain
      let request = AIRequest.make(
        feature: .linkPreviews,
        system: AIGuard.defaultSystem + """
           Summarize the destination page in at most 3 short sentences, then up to 3 key points as lines starting with "• ". \
          Do not invent content that is not in the extract. If the extract is too thin, say you could not summarize it reliably.
          """,
        prompt: AIGuard.wrapUntrusted(
          "Title: \(page.title)\nURL: \(url.absoluteString)\nDescription: \(page.description ?? "")\n\n\(page.text)",
          label: "destination page"),
        provenance: "preview:\(url.host() ?? "")",
        cacheKey: "preview:\(url.absoluteString)",
        maxTokens: 220,
        timeout: .seconds(20))
      @Dependency(\.ai) var ai
      let response = try await ai.complete(request)
      guard id == generation else { return }
      let (summary, points) = Self.split(response.text)
      preview = LinkPreview(
        url: url, title: page.title, domain: url.domain, summary: summary, points: points, warning: nil, isLoading: false)
    } catch let failure as AIFailure where failure == .disabled || failure == .cancelled {
      if id == generation { preview = nil }
    } catch {
      guard id == generation else { return }
      let message = (error as? AIFailure)?.message ?? "The destination could not be summarized."
      if var current = preview, current.url == url {
        current.isLoading = false
        current.warning = message
        preview = current
      } else {
        preview = LinkPreview(
          url: url, title: "", domain: url.domain, summary: nil, points: [], warning: message, isLoading: false)
      }
    }
  }

  nonisolated static func split(_ text: String) -> (String, [String]) {
    var summary: [String] = []
    var points: [String] = []
    for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) })
    where !line.isEmpty {
      if line.hasPrefix("•") || line.hasPrefix("-") || line.hasPrefix("*") {
        points.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "•-* ")))
      } else {
        summary.append(line)
      }
    }
    return (summary.joined(separator: " "), Array(points.prefix(3)))
  }
}

struct LinkPreviewCard: View {
  let preview: LinkPreview
  let open: () -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(preview.destinationLabel).font(.system(size: 13, weight: .semibold)).lineLimit(2)
          Text(preview.domain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        Spacer(minLength: 8)
        Button("Open", action: open)
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .semibold))
          .padding(.horizontal, 8).frame(height: 22)
          .background(Theme.accent, in: Capsule())
      }
      if preview.isLoading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Summarizing…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
      } else if let warning = preview.warning, preview.summary == nil {
        Text(warning).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
      } else {
        if let summary = preview.summary, !summary.isEmpty {
          Text(summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(preview.points, id: \.self) { point in
          Text("• \(point)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
        }
        if let warning = preview.warning {
          Text(warning).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
      }
    }
    .padding(12)
    .frame(width: 320, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x1C1D21).opacity(0.96))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    )
    .onExitCommand(perform: dismiss)
  }
}

@MainActor
enum LinkPreviewPanel {
  static let panel: NSPanel = {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    return panel
  }()

  static func show(_ card: some View, near point: NSPoint, in window: NSWindow) {
    let host = NSHostingView(rootView: card.environment(\.colorScheme, .dark))
    let size = host.fittingSize
    let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 16)
    origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
    origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
    panel.contentView = host
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
    if panel.parent != window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    panel.orderFront(nil)
  }

  static func hide() {
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    panel.contentView = nil
  }
}

struct LinkPreviewOverlay: View {
  let tab: Tab.ID
  let open: (URL) -> Void
  @State private var shiftHeld = false
  @State private var flagsMonitor: Any?
  @State private var shown: URL?

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .onAppear {
        shiftHeld = NSEvent.modifierFlags.contains(.shift)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
          let held = event.modifierFlags.contains(.shift)
          if held != shiftHeld { shiftHeld = held }
          return event
        }
      }
      .onDisappear {
        flagsMonitor.map(NSEvent.removeMonitor)
        LinkPreviewController.shared.cancel()
        LinkPreviewPanel.hide()
      }
      .onChange(of: Engine.shared.hoveredLinks[tab]) { _, url in
        LinkPreviewController.shared.hover(url, tab: tab, shift: shiftHeld)
      }
      .onChange(of: shiftHeld) { _, held in
        LinkPreviewController.shared.hover(Engine.shared.hoveredLinks[tab], tab: tab, shift: held)
      }
      .onChange(of: LinkPreviewController.shared.preview) { _, preview in
        guard let preview, let window = NSApp.keyWindow else {
          shown = nil
          LinkPreviewPanel.hide()
          return
        }
        shown = preview.url
        LinkPreviewPanel.show(
          LinkPreviewCard(
            preview: preview,
            open: { open(preview.url); LinkPreviewController.shared.cancel(); LinkPreviewPanel.hide() },
            dismiss: { LinkPreviewController.shared.cancel(); LinkPreviewPanel.hide() }
          ),
          near: NSEvent.mouseLocation, in: window)
      }
  }
}
