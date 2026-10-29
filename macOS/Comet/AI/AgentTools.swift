import Foundation
@preconcurrency import EngineCore

enum AgentTools {
  @MainActor
  static func pageBrief(tab: Tab.ID, url: URL, title: String) async -> String {
    let text = await runScript(PageExtractor.script, tab: tab)
    let parsed = text.flatMap { PageExtractor.parse($0, tab: tab, url: url, fallbackTitle: title) }
    let body = String((parsed?.text ?? "").prefix(4_000))
    return """
      Title: \(parsed?.title ?? title)
      URL: \(url.absoluteString)
      Readable text:
      \(body.isEmpty ? "(The page text could not be read.)" : body)
      """
  }

  @MainActor
  static func run(_ call: AgentCall, tab: Tab.ID) async -> String {
    let activity = AgentActivity.shared
    guard activity.tab == tab, !activity.phaseIsBlocked else { return "Not run. Agent is paused, stopped, or aimed at another tab." }
    guard let contents = Engine.shared.tabs[tab] else { return "This tab has no page loaded." }
    switch call.name {
    case "get_current_page":
      return "title=\(contents.title) url=\(contents.url?.absoluteString ?? "")"
    case "get_page_text":
      return await pageBrief(tab: tab, url: contents.url ?? URL(string: "about:blank")!, title: contents.title)
    case "get_page_metadata":
      return await jsonScript(metadataScript, tab: tab)
    case "get_page_structure", "get_interactive_elements":
      return await jsonScript(elementsScript, tab: tab)
    case "get_selected_text":
      return Engine.shared.selections[tab] ?? "(Nothing is selected.)"
    case "find_page_content":
      let query = call.arguments["query"] ?? ""
      guard !query.isEmpty else { return "Missing query." }
      let brief = await pageBrief(tab: tab, url: contents.url ?? URL(string: "about:blank")!, title: contents.title)
      return brief.localizedCaseInsensitiveContains(query) ? "The readable text contains “\(query)”." : "The readable text does not contain “\(query)”."
    case "inspect_element":
      guard let selector = safeSelector(call.arguments["selector"]) else { return "The selector is missing or not allowed." }
      return await jsonScript(inspectScript(selector), tab: tab)
    case "click_element":
      guard let selector = safeSelector(call.arguments["selector"]) else { return "The selector is missing or not allowed." }
      let before = contents.url
      let result = await jsonScript(clickScript(selector), tab: tab)
      try? await Task.sleep(for: .milliseconds(400))
      let after = Engine.shared.tabs[tab]?.url
      return "\(result) url=\(after?.absoluteString ?? "") changed=\(before != after)"
    case "fill_input":
      guard let selector = safeSelector(call.arguments["selector"]) else { return "The selector is missing or not allowed." }
      let value = String((call.arguments["value"] ?? "").prefix(2_000))
      return await jsonScript(fillScript(selector, value), tab: tab)
    case "select_option":
      guard let selector = safeSelector(call.arguments["selector"]) else { return "The selector is missing or not allowed." }
      return await jsonScript(selectScript(selector, call.arguments["value"] ?? ""), tab: tab)
    case "toggle_control":
      guard let selector = safeSelector(call.arguments["selector"]) else { return "The selector is missing or not allowed." }
      return await jsonScript(toggleScript(selector), tab: tab)
    case "press_key":
      let key = call.arguments["key"] ?? ""
      guard ["Enter", "Escape", "Tab", "ArrowDown", "ArrowUp"].contains(key) else { return "That key is not allowed." }
      return await jsonScript(keyScript(key), tab: tab)
    case "scroll_page":
      let amount = Int(call.arguments["y"] ?? "400") ?? 400
      let y = max(-2_000, min(2_000, amount))
      return await jsonScript("(() => { window.scrollBy(0, \(y)); return JSON.stringify({ok:true,y:window.scrollY}); })()", tab: tab)
    case "navigate_to_url", "open_link":
      guard let destination = httpURL(call.arguments["url"]) else { return "The URL must be http or https." }
      contents.loadURL(destination)
      return "Navigating to \(destination.absoluteString)."
    case "go_back":
      contents.goBack()
      return "Went back."
    case "go_forward":
      contents.goForward()
      return "Went forward."
    case "reload_page":
      contents.reload()
      return "Reloaded."
    case "wait_for_page_state":
      let wanted = call.arguments["url"]
      let deadline = Date().addingTimeInterval(8)
      while Date() < deadline {
        if Task.isCancelled || AgentActivity.shared.phaseIsBlocked { return "Wait cancelled." }
        if let wanted, contents.url?.absoluteString == wanted { return "URL is \(wanted)." }
        if wanted == nil, !contents.isLoading { return "The page is not loading. url=\(contents.url?.absoluteString ?? "")" }
        try? await Task.sleep(for: .milliseconds(200))
      }
      return "Timed out. url=\(contents.url?.absoluteString ?? "") loading=\(contents.isLoading)"
    default:
      return "\(call.name) is not available."
    }
  }

  @MainActor
  private static func jsonScript(_ script: String, tab: Tab.ID) async -> String {
    await runScript(script, tab: tab) ?? "The page did not return a result."
  }

  @MainActor
  static func runScript(_ script: String, tab: Tab.ID) async -> String? {
    guard let contents = Engine.shared.tabs[tab] else { return nil }
    return await withCheckedContinuation { continuation in
      contents.evaluateJavaScript(script) { value in
        MainActor.assumeIsolated { continuation.resume(returning: value) }
      }
    }
  }

  static func safeSelector(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selector.isEmpty, selector.count <= 200, !selector.contains("\n"), !selector.contains("{"),
      !selector.lowercased().contains("javascript:")
    else { return nil }
    return selector
  }

  static func httpURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      url.host() != nil
    else { return nil }
    return url
  }

  private static func jsString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text]),
      var encoded = String(data: data, encoding: .utf8), encoded.count >= 2
    else { return "\"\"" }
    encoded.removeFirst()
    encoded.removeLast()
    return encoded
  }

  private static let metadataScript = """
    (() => JSON.stringify({
      title: document.title || "",
      url: location.href,
      description: document.querySelector('meta[name="description"]')?.content || "",
      canonical: document.querySelector('link[rel="canonical"]')?.href || "",
      headings: [...document.querySelectorAll("h1,h2")].slice(0, 12).map((node) => node.innerText.trim()).filter(Boolean)
    }))()
    """

  private static let elementsScript = """
    (() => JSON.stringify([...document.querySelectorAll("a,button,input,textarea,select,[role=button]")].slice(0, 30).map((node) => ({
      tag: node.tagName, id: node.id || "", type: node.getAttribute("type") || "",
      text: (node.innerText || node.getAttribute("aria-label") || node.getAttribute("placeholder") || "").trim().slice(0, 80),
      href: node.href || ""
    }))))()
    """

  private static func inspectScript(_ selector: String) -> String {
    """
    (() => {
      const node = document.querySelector(\(jsString(selector)));
      if (!node) return JSON.stringify({ok:false, error:"Element not found"});
      const style = getComputedStyle(node);
      return JSON.stringify({ok:true, tag:node.tagName, id:node.id || "", text:(node.innerText||"").trim().slice(0,300),
        role: node.getAttribute("role") || "", hidden: node.hidden, color: style.color, font: style.fontSize});
    })()
    """
  }

  private static func clickScript(_ selector: String) -> String {
    """
    (() => {
      const node = document.querySelector(\(jsString(selector)));
      if (!node) return JSON.stringify({ok:false, error:"Element not found"});
      const rect = node.getBoundingClientRect();
      if (rect.width < 1 || rect.height < 1) return JSON.stringify({ok:false, error:"Element is not visible"});
      node.click();
      return JSON.stringify({ok:true, text:(node.innerText||"").trim().slice(0,160)});
    })()
    """
  }

  private static func fillScript(_ selector: String, _ value: String) -> String {
    """
    (() => {
      const node = document.querySelector(\(jsString(selector)));
      if (!node || !("value" in node)) return JSON.stringify({ok:false, error:"Not a text field"});
      node.focus();
      node.value = \(jsString(value));
      node.dispatchEvent(new Event("input", {bubbles:true}));
      node.dispatchEvent(new Event("change", {bubbles:true}));
      return JSON.stringify({ok:true});
    })()
    """
  }

  private static func selectScript(_ selector: String, _ value: String) -> String {
    """
    (() => {
      const node = document.querySelector(\(jsString(selector)));
      if (!node || node.tagName !== "SELECT") return JSON.stringify({ok:false, error:"Not a select"});
      node.value = \(jsString(value));
      node.dispatchEvent(new Event("change", {bubbles:true}));
      return JSON.stringify({ok:true, value:node.value});
    })()
    """
  }

  private static func toggleScript(_ selector: String) -> String {
    """
    (() => {
      const node = document.querySelector(\(jsString(selector)));
      if (!node || node.tagName !== "INPUT") return JSON.stringify({ok:false, error:"Not a checkbox or radio"});
      node.click();
      return JSON.stringify({ok:true, checked:!!node.checked});
    })()
    """
  }

  private static func keyScript(_ key: String) -> String {
    """
    (() => {
      const target = document.activeElement || document.body;
      target.dispatchEvent(new KeyboardEvent("keydown", {key:\(jsString(key)), bubbles:true}));
      return JSON.stringify({ok:true, key:\(jsString(key))});
    })()
    """
  }
}

extension AgentActivity {
  var phaseIsBlocked: Bool {
    phase == .paused || phase == .cancelled || phase == .idle
  }
}
