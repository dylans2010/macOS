import AppKit
import ComposableArchitecture
import SwiftUI
@preconcurrency import EngineCore

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // A saved choice. Local pages still show developer chrome when this is off.
  static var developerMode: Self { Self[.appStorage("developerMode"), default: false] }
}

enum DeveloperModePolicy {
  static func showsChrome(url: URL, enabled: Bool) -> Bool {
    enabled || url.isDeveloperPage
  }
}

extension URL {
  var showsDeveloperChrome: Bool {
    @Shared(.developerMode) var enabled
    return DeveloperModePolicy.showsChrome(url: self, enabled: enabled)
  }
}

struct DeveloperToolsView: View {
  let tab: Tab.ID
  @State private var facts = "Loading page facts…"
  @State private var selector = "h1"
  @State private var inspection = ""
  @State private var consoleInput = "document.title"
  @State private var consoleOutput = ""
  @State private var storage = ""
  @State private var status: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Developer Tools").font(.headline)
          Spacer()
          Button("Done") {
            guard let sheet = NSApp.keyWindow, let parent = sheet.sheetParent else { return }
            parent.endSheet(sheet)
          }
        }
        Text("Scripts run in an isolated world. They can read the DOM. They cannot see the page’s own JavaScript variables. Chrome’s DevTools has the network panel, the accessibility tree, and the page console.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        HStack {
          Button("Chrome Console") { Engine.shared.perform(tab) { $0.showConsole() } }
          Button("Inspect Element") { Engine.shared.perform(tab) { $0.inspectElement() } }
          Button("Reload Ignoring Cache") { Engine.shared.perform(tab) { $0.reloadBypassingCache() } }
          Button("Copy Facts") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(facts, forType: .string) }
        }
        GroupBox("Page") { Text(facts).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
        GroupBox("Element") {
          HStack {
            TextField("CSS selector", text: $selector).textFieldStyle(.roundedBorder)
            Button("Inspect") { Task { await inspect() } }
          }
          if !inspection.isEmpty { Text(inspection).font(.system(size: 12, design: .monospaced)) }
        }
        GroupBox("Console") {
          TextField("Expression", text: $consoleInput).textFieldStyle(.roundedBorder)
          Button("Run") { Task { await runConsole() } }
          if !consoleOutput.isEmpty { Text(consoleOutput).font(.system(size: 12, design: .monospaced)) }
        }
        GroupBox("Storage") {
          Text("Shows localStorage keys and non-HTTP-only cookie names. Values are left out of the copy below.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
          Button("Read") { Task { await readStorage() } }
          Button("Clear localStorage…", action: clearStorage)
          if !storage.isEmpty { Text(storage).font(.system(size: 12, design: .monospaced)) }
        }
        Text("Resource timing and response bodies are not available outside Chrome DevTools. Comet does not invent them.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        if let status { Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }
      }
      .padding(16)
      .frame(width: 520)
    }
    .task { await loadFacts() }
  }

  private func loadFacts() async {
    let script = """
      (() => JSON.stringify({
        href: location.href, origin: location.origin, title: document.title, ready: document.readyState,
        width: window.innerWidth, height: window.innerHeight
      }))()
      """
    facts = await AgentTools.runScript(script, tab: tab) ?? "This tab has no page."
  }

  private func inspect() async {
    guard let selector = AgentTools.safeSelector(selector) else { inspection = "That selector is not allowed."; return }
    let script = """
      (() => {
        const node = document.querySelector(\(json(selector)));
        if (!node) return "Element not found";
        const style = getComputedStyle(node);
        return [node.tagName, node.id, (node.innerText||"").trim().slice(0,180), style.color, style.fontSize].join(" | ");
      })()
      """
    inspection = await AgentTools.runScript(script, tab: tab) ?? "No result"
  }

  private func runConsole() async {
    let source = String(consoleInput.prefix(4_000))
    let script = """
      (() => { try { const value = (0, eval)(\(json(source))); return String(value); } catch (error) { return "Error: " + error; } })()
      """
    consoleOutput = await AgentTools.runScript(script, tab: tab) ?? "No result"
  }

  private func readStorage() async {
    let script = """
      (() => {
        const keys = [];
        for (let i = 0; i < localStorage.length; i++) keys.push(localStorage.key(i));
        const cookies = document.cookie.split(";").map((item) => item.split("=")[0].trim()).filter(Boolean);
        return JSON.stringify({ localStorage: keys, cookieNames: cookies });
      })()
      """
    storage = await AgentTools.runScript(script, tab: tab) ?? "Storage could not be read."
  }

  private func clearStorage() {
    let alert = NSAlert()
    alert.messageText = "Clear localStorage for this page?"
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task {
      _ = await AgentTools.runScript("(() => { localStorage.clear(); return \"cleared\"; })()", tab: tab)
      status = "localStorage was cleared."
      await readStorage()
    }
  }

  private func json(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text]),
      var encoded = String(data: data, encoding: .utf8), encoded.count >= 2
    else { return "\"\"" }
    encoded.removeFirst()
    encoded.removeLast()
    return encoded
  }
}
