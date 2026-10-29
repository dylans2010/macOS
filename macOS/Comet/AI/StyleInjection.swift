import Foundation

// The page script installs one style element and, only when the script changed or the document navigated,
// runs the user's JavaScript in the isolated world evaluateJavaScript already uses. The user source is a
// function body argument, not concatenated into this wrapper, and the only object handed to it is cleanup.

enum StyleJSON {
  static func string(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text]),
      var encoded = String(data: data, encoding: .utf8), encoded.count >= 2
    else { return "\"\"" }
    encoded.removeFirst()
    encoded.removeLast()
    return encoded
  }

  static func scopes(_ scopes: [StyleScope]) -> String {
    let payload = scopes.map { ["hosts": $0.hosts, "excluded": $0.excludedPaths] }
    guard JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: data, encoding: .utf8)
    else { return "[]" }
    return text
  }
}

enum StyleInjection {
  static let library = """
    function cometHostMatches(host, rule) {
      rule = String(rule || "").trim().toLowerCase();
      if (!rule || rule === "*" || rule.indexOf("/") !== -1) return false;
      if (rule.startsWith("*.")) {
        const apex = rule.slice(2);
        if (!apex || apex.indexOf("*") !== -1) return false;
        return host === apex || host.endsWith("." + apex);
      }
      if (rule.indexOf("*") !== -1) return false;
      return host === rule;
    }
    function cometExcludes(path, excluded) {
      let rule = String(excluded || "").trim();
      if (!rule) return false;
      if (!rule.startsWith("/")) rule = "/" + rule;
      if (rule.length > 1 && rule.endsWith("/")) rule = rule.slice(0, -1);
      return path === rule || path.startsWith(rule + "/");
    }
    function cometRuleMatches(rule) {
      rule = String(rule || "").trim();
      if (!rule) return false;
      const host = String(location.hostname || "").toLowerCase();
      const path = location.pathname || "/";
      const scheme = String(location.protocol || "").replace(/:$/, "").toLowerCase();
      const sep = rule.indexOf("://");
      if (sep !== -1) {
        const want = rule.slice(0, sep).toLowerCase();
        if (want !== "*" && want !== scheme) return false;
        const rest = rule.slice(sep + 3);
        const slash = rest.indexOf("/");
        const hostRule = slash === -1 ? rest : rest.slice(0, slash);
        if (!cometHostMatches(host, hostRule)) return false;
        if (slash === -1) return true;
        let pathRule = "/" + rest.slice(slash + 1);
        if (pathRule === "/*" || pathRule === "/") return true;
        const wild = pathRule.endsWith("*");
        if (wild) pathRule = pathRule.slice(0, -1);
        if (!pathRule || pathRule === "/") return true;
        if (wild) return path.startsWith(pathRule);
        return path === pathRule || path.startsWith(pathRule.endsWith("/") ? pathRule : pathRule + "/");
      }
      return cometHostMatches(host, rule);
    }
    function cometScopeMatches(scope) {
      const path = location.pathname || "/";
      const excluded = scope.excluded || [];
      for (const item of excluded) if (cometExcludes(path, item)) return false;
      return (scope.hosts || []).some(cometRuleMatches);
    }
    function cometToneApply() {
      if (!document.body) return;
      const media = { IMG: 1, VIDEO: 1, CANVAS: 1, SVG: 1, PICTURE: 1, IFRAME: 1, EMBED: 1, OBJECT: 1 };
      const skip = (el) => !el || el.id === "comet-zap-root" || el.id === "comet-styles" || el.id === "comet-zap-preview" || el.tagName === "SCRIPT" || el.tagName === "STYLE" || el.tagName === "LINK";
      const pinned = [];
      const all = document.body.getElementsByTagName("*");
      for (let index = 0; index < all.length; index++) {
        const el = all[index];
        if (skip(el)) continue;
        const position = getComputedStyle(el).position;
        if (position === "fixed" || position === "sticky") pinned.push(el);
      }
      const next = new Set();
      for (const el of pinned) if (!media[el.tagName]) next.add(el);
      const hasPin = (el) => pinned.some((pin) => pin !== el && el.contains(pin));
      const walk = (el) => {
        if (skip(el) || next.has(el)) return;
        if (hasPin(el)) {
          for (const child of el.children) walk(child);
          return;
        }
        if (media[el.tagName]) return;
        next.add(el);
      };
      for (const child of document.body.children) walk(child);
      document.querySelectorAll(".comet-tone").forEach((el) => { if (!next.has(el)) el.classList.remove("comet-tone"); });
      next.forEach((el) => el.classList.add("comet-tone"));
    }
    function cometToneStop() {
      if (globalThis.__cometToneObserver) {
        globalThis.__cometToneObserver.disconnect();
        globalThis.__cometToneObserver = null;
      }
      document.querySelectorAll(".comet-tone").forEach((el) => el.classList.remove("comet-tone"));
    }
    function cometToneStart() {
      cometToneApply();
      globalThis.__cometApplyTone = cometToneApply;
      if (globalThis.__cometToneObserver || !document.body) return;
      let pending = 0;
      const observer = new MutationObserver(() => {
        pending += 1;
        const token = pending;
        setTimeout(() => {
          if (token !== pending) return;
          const node = document.getElementById("comet-styles");
          if (!node || node.textContent.indexOf(".comet-tone") === -1) {
            cometToneStop();
            return;
          }
          cometToneApply();
        }, 120);
      });
      observer.observe(document.body, { childList: true, subtree: true });
      globalThis.__cometToneObserver = observer;
    }
    function cometCleanup() {
      const cleanup = globalThis.__cometStyleCleanup;
      globalThis.__cometStyleCleanup = null;
      if (typeof cleanup === "function") { try { cleanup(); } catch (error) {} }
    }
    """

  static func source(css: String, script: String, scopes: [StyleScope], runScript: Bool) -> String {
    """
    (() => {
      \(library)
      const css = \(StyleJSON.string(css));
      const source = \(StyleJSON.string(script));
      const runScript = \(runScript ? "true" : "false");
      const scopes = \(StyleJSON.scopes(scopes));
      if (scopes.length && !scopes.some(cometScopeMatches)) {
        cometCleanup();
        cometToneStop();
        const stale = document.getElementById("comet-styles");
        if (stale) stale.remove();
        return "scope";
      }
      let node = document.getElementById("comet-styles");
      if (!css) {
        if (node) node.remove();
        cometToneStop();
      } else {
        if (!node) {
          node = document.createElement("style");
          node.id = "comet-styles";
        }
        node.textContent = css;
        const parent = document.head || document.documentElement;
        parent.appendChild(node);
        if (css.indexOf(".comet-tone") !== -1) cometToneStart();
        else cometToneStop();
      }
      if (!runScript) return "ok";
      cometCleanup();
      if (!source) return "ok";
      try {
        const bucket = [];
        const comet = Object.freeze({
          onCleanup(fn) { if (typeof fn === "function") globalThis.__cometUserCleanup = fn; }
        });
        globalThis.__cometStyleCleanup = () => {
          for (const fn of bucket) { try { fn(); } catch (error) {} }
          const user = globalThis.__cometUserCleanup;
          globalThis.__cometUserCleanup = null;
          if (typeof user === "function") { try { user(); } catch (error) {} }
        };
        const trackedInterval = (fn, ms) => {
          const id = setInterval(fn, ms);
          bucket.push(() => clearInterval(id));
          return id;
        };
        const trackedTimeout = (fn, ms) => {
          const id = setTimeout(fn, ms);
          bucket.push(() => clearTimeout(id));
          return id;
        };
        const trackedListen = (type, fn, options) => {
          document.addEventListener(type, fn, options);
          bucket.push(() => document.removeEventListener(type, fn, options));
        };
        const run = new Function("comet", "setInterval", "setTimeout", "addEventListener", source);
        run(comet, trackedInterval, trackedTimeout, trackedListen);
      } catch (error) {
        const message = error && error.message ? error.message : String(error);
        return "script:" + String(message).slice(0, 300);
      }
      return "ok";
    })()
    """
  }
}
