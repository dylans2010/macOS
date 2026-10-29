import Foundation

// Zap draws its highlight in the page and records a description of the element. The selector is built here, from
// that description, so a page cannot hand Comet a stylesheet. Hiding is a CSS rule on the site's style, not a
// change to the website.

struct ZapPoll: Decodable {
  var active: Bool
  var cancelled: Bool
  var chain: [StyleNode]?
}

@MainActor
enum StyleZap {
  private static var poll: Task<Void, Never>?
  private static var tab: UUID?
  private static let chainLibrary = """
    function cometIdent(value) { return /^[A-Za-z_][A-Za-z0-9_-]*$/.test(value || ""); }
    function cometCount(selector) { try { return document.querySelectorAll(selector).length; } catch (error) { return 99; } }
    function cometNode(el) {
      const tag = el.tagName.toLowerCase();
      const classes = [...el.classList].filter((name) => cometIdent(name)).slice(0, 6);
      const classCount = {};
      for (const name of classes) classCount[name] = cometCount(tag + "." + name);
      const names = ["data-testid", "data-test", "data-cy", "data-id", "name", "aria-label", "role"];
      const attributes = {};
      const attributeCount = {};
      for (const name of names) {
        const value = el.getAttribute(name);
        if (!value || value.length > 79) continue;
        if (!/^[A-Za-z0-9_ .:-]+$/.test(value)) continue;
        attributes[name] = value;
        attributeCount[name + "=" + value] = cometCount(tag + "[" + name + "='" + value + "']");
      }
      let nth = 1;
      let siblings = 1;
      if (el.parentElement) {
        const same = [...el.parentElement.children].filter((child) => child.tagName === el.tagName);
        siblings = same.length;
        nth = same.indexOf(el) + 1;
      }
      const onlyText = [...el.childNodes].every((node) => node.nodeType !== 1);
      return {
        tag, id: cometIdent(el.id) ? el.id : "", idCount: cometIdent(el.id) ? cometCount("#" + el.id) : 0,
        classes, classCount, attributes, attributeCount, nth, siblings,
        text: onlyText ? (el.textContent || "").trim().slice(0, 40) : ""
      };
    }
    function cometChain(el) {
      const chain = [];
      let node = el;
      while (node && node.nodeType === 1 && node !== document.documentElement && chain.length < 10) {
        if (node.id !== "comet-zap-root" && node.id !== "comet-styles" && node.id !== "comet-zap-preview") chain.push(cometNode(node));
        if (node === document.body) break;
        node = node.parentElement;
      }
      return chain;
    }
    """

  static func snapshotScript(_ selector: String) -> String? {
    guard StyleSelector.isSafe(selector) else { return nil }
    return """
      (() => {
        \(chainLibrary)
        const el = document.querySelector(\(StyleJSON.string(selector)));
        if (!el) return "";
        return JSON.stringify(cometChain(el));
      })()
      """
  }

  static func installScript(scopes: [StyleScope]) -> String {
    """
    (() => {
      \(StyleInjection.library)
      \(chainLibrary)
      const scopes = \(StyleJSON.scopes(scopes));
      if (scopes.length && !scopes.some(cometScopeMatches)) return "scope";
      const previous = document.getElementById("comet-zap-root");
      if (previous) previous.remove();
      const root = document.createElement("div");
      root.id = "comet-zap-root";
      root.style.all = "initial";
      root.style.position = "fixed";
      root.style.left = "0";
      root.style.top = "0";
      root.style.right = "0";
      root.style.bottom = "0";
      root.style.zIndex = "2147483646";
      root.style.cursor = "crosshair";
      root.style.background = "transparent";
      const box = document.createElement("div");
      box.style.position = "fixed";
      box.style.pointerEvents = "none";
      box.style.border = "2px solid #4C7DFF";
      box.style.background = "rgba(76, 125, 255, 0.16)";
      box.style.borderRadius = "4px";
      box.style.boxSizing = "border-box";
      box.style.display = "none";
      root.appendChild(box);
      (document.documentElement || document.body).appendChild(root);
      const state = { active: true, cancelled: false, chain: null };
      globalThis.__cometZap = state;
      const targetAt = (x, y) => {
        root.style.pointerEvents = "none";
        let el = document.elementFromPoint(x, y);
        root.style.pointerEvents = "auto";
        while (el && (el.id === "comet-zap-root" || el.id === "comet-styles" || el.id === "comet-zap-preview" || root.contains(el))) {
          el = el.parentElement;
        }
        return el;
      };
      const onMove = (event) => {
        const el = targetAt(event.clientX, event.clientY);
        if (!el) { box.style.display = "none"; return; }
        const rect = el.getBoundingClientRect();
        box.style.display = "block";
        box.style.left = rect.left + "px";
        box.style.top = rect.top + "px";
        box.style.width = Math.max(rect.width, 2) + "px";
        box.style.height = Math.max(rect.height, 2) + "px";
      };
      const finish = (event) => {
        event.preventDefault();
        event.stopPropagation();
        const el = targetAt(event.clientX, event.clientY);
        if (el) state.chain = cometChain(el);
        state.active = false;
        root.remove();
        document.removeEventListener("keydown", onKey, true);
      };
      const onKey = (event) => {
        if (event.key !== "Escape") return;
        event.preventDefault();
        state.cancelled = true;
        state.active = false;
        root.remove();
        document.removeEventListener("keydown", onKey, true);
      };
      root.addEventListener("mousemove", onMove);
      root.addEventListener("click", finish);
      document.addEventListener("keydown", onKey, true);
      return "ok";
    })()
    """
  }

  static func previewScript(_ selector: String) -> String? {
    guard StyleSelector.isSafe(selector) else { return nil }
    let css = StyleJSON.string("\(selector) { display: none !important; }")
    let query = StyleJSON.string(selector)
    return """
      (() => {
        let node = document.getElementById("comet-zap-preview");
        if (!node) {
          node = document.createElement("style");
          node.id = "comet-zap-preview";
          (document.head || document.documentElement).appendChild(node);
        }
        node.textContent = \(css);
        try { return String(document.querySelectorAll(\(query)).length); } catch (error) { return "0"; }
      })()
      """
  }

  static let pollScript = """
    (() => {
      const state = globalThis.__cometZap;
      if (!state) return "";
      return JSON.stringify({ active: !!state.active, cancelled: !!state.cancelled, chain: state.chain || null });
    })()
    """

  static let stopScript = """
    (() => {
      const root = document.getElementById("comet-zap-root");
      if (root) root.remove();
      const preview = document.getElementById("comet-zap-preview");
      if (preview) preview.remove();
      globalThis.__cometZap = null;
      return "ok";
    })()
    """

  static func begin(style: SiteStyle) {
    guard style.enabled else {
      StyleDiagnostics.shared.message = "Turn the style on before hiding elements."
      return
    }
    guard let tab = FrontBrowser.tabID, let contents = Engine.shared.tabs[tab] else {
      StyleDiagnostics.shared.message = "Open a page before using Zap."
      return
    }
    guard let url = contents.url ?? FrontBrowser.url, StyleMatch.matches(url, style, requiringEnabled: false) else {
      StyleDiagnostics.shared.message = "Zap only hides elements on this style's sites."
      return
    }
    self.tab = tab
    stopPolling()
    StyleSiteSession.shared.zap = .selecting
    let scopes = [StyleScope(hosts: style.hosts, excludedPaths: style.excludedPaths)]
    contents.evaluateJavaScript(installScript(scopes: scopes)) { result in
      Task { @MainActor in
        guard StyleSiteSession.shared.zap == .selecting else { return }
        if result == nil {
          StyleDiagnostics.shared.message = "Zap could not start. The page was not ready."
          StyleSiteSession.shared.zap = .idle
        } else if result == "scope" {
          StyleDiagnostics.shared.message = "Zap stayed off because this page is a different site."
          StyleSiteSession.shared.zap = .idle
        }
      }
    }
    startPolling()
  }

  static func cancel() {
    stopPolling()
    StyleSiteSession.shared.zap = .idle
    guard let tab, let contents = Engine.shared.tabs[tab] else { return }
    contents.evaluateJavaScript(stopScript) { _ in }
  }

  static func choose(_ index: Int, style: SiteStyle) {
    guard case var .confirming(confirmation) = StyleSiteSession.shared.zap, confirmation.candidates.indices.contains(index) else { return }
    confirmation.index = index
    confirmation.matches = 0
    StyleSiteSession.shared.zap = .confirming(confirmation)
    preview(confirmation.candidates[index].selector, style: style)
  }

  static func confirm(style: SiteStyle) {
    guard case let .confirming(confirmation) = StyleSiteSession.shared.zap,
      confirmation.candidates.indices.contains(confirmation.index)
    else { return }
    let candidate = confirmation.candidates[confirmation.index]
    guard StyleSelector.isSafe(candidate.selector) else { return }
    guard style.hidden.count < 100 else {
      StyleDiagnostics.shared.message = "Restore a hidden element before hiding another."
      return
    }
    StyleEditing.update(style.id, soon: false) { item in
      item.hidden.removeAll { $0.selector == candidate.selector }
      item.hidden.append(
        StyleHidden(id: UUID(), selector: candidate.selector, label: candidate.label, confidence: candidate.confidence))
    }
    stopPolling()
    StyleSiteSession.shared.zap = .idle
    let current = tab
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(350))
      if let current, let contents = Engine.shared.tabs[current] {
        contents.evaluateJavaScript(stopScript) { _ in }
      }
    }
  }

  private static func preview(_ selector: String, style: SiteStyle) {
    guard let script = previewScript(selector), let tab, let contents = Engine.shared.tabs[tab] else { return }
    guard StyleMatch.matches(contents.url ?? URL(string: "about:blank")!, style, requiringEnabled: false) || contents.url == nil else { return }
    contents.evaluateJavaScript(script) { result in
      Task { @MainActor in
        guard case var .confirming(confirmation) = StyleSiteSession.shared.zap,
          confirmation.candidates[confirmation.index].selector == selector
        else { return }
        confirmation.matches = Int(result ?? "") ?? 0
        StyleSiteSession.shared.zap = .confirming(confirmation)
      }
    }
  }

  private static func startPolling() {
    poll?.cancel()
    poll = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(90))
        guard !Task.isCancelled else { return }
        await tick()
      }
    }
  }

  private static func stopPolling() {
    poll?.cancel()
    poll = nil
  }

  private static func tick() async {
    guard let tab, let contents = Engine.shared.tabs[tab] else {
      StyleSiteSession.shared.zap = .idle
      stopPolling()
      return
    }
    let result: String? = await withCheckedContinuation { continuation in
      contents.evaluateJavaScript(pollScript) { value in
        continuation.resume(returning: value)
      }
    }
    guard !Task.isCancelled else { return }
    guard let result, let data = result.data(using: .utf8), !result.isEmpty,
      let payload = try? JSONDecoder().decode(ZapPoll.self, from: data)
    else { return }
    if payload.cancelled {
      cancel()
      return
    }
    guard case .selecting = StyleSiteSession.shared.zap, let chain = payload.chain, !chain.isEmpty else { return }
    let candidates = StyleSelector.candidates(for: chain)
    guard !candidates.isEmpty else {
      StyleDiagnostics.shared.message = "Choose a smaller part of the page. That element could not be hidden safely."
      cancel()
      return
    }
    StyleSiteSession.shared.zap = .confirming(ZapConfirmation(candidates: candidates, index: 0, matches: 0))
    if let style = StyleSiteSession.shared.styleID.flatMap({ id in StyleEditing.current().first { $0.id == id } }) {
      preview(candidates[0].selector, style: style)
    }
  }
}
