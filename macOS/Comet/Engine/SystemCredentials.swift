import AppKit
import AuthenticationServices
import Foundation
import Security

enum CredentialPage {
  // An origin includes a non-default port. Without it, https://example.com:8443
  // would be treated as the same origin as https://example.com, and a credential
  // for one could be offered on the other. An explicitly default port
  // (https://example.com:443) normalises to the portless form.
  static func origin(_ url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
      let host = url.host()?.lowercased(), !host.isEmpty, !host.contains(" ")
    else { return nil }
    let defaultPort = scheme == "https" ? 443 : 80
    if let port = url.port, port != defaultPort {
      return "\(scheme)://\(host):\(port)"
    }
    return "\(scheme)://\(host)"
  }

  static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
    guard let a = origin(left), let b = origin(right) else { return false }
    return a == b
  }
}

enum PasswordFieldProbe {
  // Isolated-world read of the focused control. It never reads or writes values.
  // It also never reads a cross-origin frame: accessing one throws or returns
  // nothing, and that frame is skipped, so its fields are never reported.
  // A username-only step is reported too: a field with autocomplete="username"
  // qualifies on its own, because that step has no password field yet. A bare
  // email field does not, so newsletter and search forms are not login forms.
  static let script = """
    (() => {
      const classify = (el, doc) => {
        if (!el || !el.tagName || el.tagName !== "INPUT") return "";
        const type = (el.getAttribute("type") || "text").toLowerCase();
        const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
        if (ac === "username") return "username";
        const scope = el.form || doc || document;
        const hasPassword = !!(scope.querySelector && scope.querySelector('input[type="password"]'));
        if (!hasPassword) return "";
        if (type === "password" || ac === "current-password" || ac === "new-password") return "password";
        if (type === "email" || ac === "email") return "username";
        return "";
      };
      const root = document.documentElement;
      if (root && root.dataset && root.dataset.cometPasswordListener !== "1") {
        root.dataset.cometPasswordListener = "1";
        document.addEventListener("focusin", (event) => {
          root.dataset.cometPasswordField = classify(event.target, document);
        }, true);
        document.addEventListener("focusout", () => {
          root.dataset.cometPasswordField = "";
        }, true);
      }
      const rectOf = (el, dx, dy) => {
        if (!el || !el.getBoundingClientRect) return "";
        const r = el.getBoundingClientRect();
        if (!r || r.width < 2 || r.height < 2) return "";
        return [Math.round(r.x + dx), Math.round(r.y + dy), Math.round(r.width), Math.round(r.height)].join(",");
      };
      const docs = [{doc: document, dx: 0, dy: 0}];
      try {
        const frames = (typeof document.querySelectorAll === "function") ? document.querySelectorAll("iframe") : [];
        for (let i = 0; i < frames.length; i++) {
          try {
            const inner = frames[i].contentDocument;
            if (!inner || !inner.querySelector) continue;
            const fr = frames[i].getBoundingClientRect ? frames[i].getBoundingClientRect() : null;
            docs.push({doc: inner, dx: fr ? fr.x : 0, dy: fr ? fr.y : 0});
          } catch (e) {}
        }
      } catch (e) {}
      const findIn = (entry, selector) => {
        if (!entry.doc.querySelector) return null;
        return entry.doc.querySelector(selector);
      };
      const focused = document.querySelector ? document.querySelector("input:focus") : null;
      let pass = null, passDoc = null;
      for (let i = 0; i < docs.length; i++) {
        const found = findIn(docs[i], 'input[type="password"]');
        if (found) { pass = found; passDoc = docs[i]; break; }
      }
      if (!pass) {
        let stepUser = null, stepDoc = null;
        for (let i = 0; i < docs.length; i++) {
          const found = findIn(docs[i], 'input[autocomplete="username"]');
          if (found) { stepUser = found; stepDoc = docs[i]; break; }
        }
        if (!stepUser) return "";
        let kind = classify(focused, document);
        if (!kind && root && root.dataset) kind = root.dataset.cometPasswordField || "";
        if (kind !== "username") kind = "username";
        return kind + "@" + rectOf(stepUser, stepDoc.dx, stepDoc.dy) + "|";
      }
      let kind = classify(focused, document);
      if (!kind && root && root.dataset) kind = root.dataset.cometPasswordField || "";
      if (kind !== "password" && kind !== "username") kind = "present";
      const scope = (focused && focused.form) || pass.form || passDoc.doc;
      const user = scope.querySelector ? scope.querySelector('input[autocomplete="username"], input[type="email"], input[name="username" i]') : null;
      return kind + "@" + rectOf(user, passDoc.dx, passDoc.dy) + "|" + rectOf(pass, passDoc.dx, passDoc.dy);
    })()
    """

  // Swift mirror of the script's classification, for tests and callers that
  // already have a field's attributes. A username step needs no password yet.
  static func isLoginField(tag: String, type: String, autocomplete: String, formHasPassword: Bool) -> String {
    guard tag.uppercased() == "INPUT" else { return "" }
    let type = type.lowercased()
    let autocomplete = autocomplete.lowercased()
    if autocomplete == "username" { return "username" }
    guard formHasPassword else { return "" }
    if type == "password" || autocomplete == "current-password" || autocomplete == "new-password" { return "password" }
    if type == "email" || autocomplete == "email" { return "username" }
    return ""
  }
}

enum PasswordFieldGeometry {
  struct Target: Equatable {
    var kind: String
    var username: CGRect?
    var password: CGRect?
  }

  static func parse(_ raw: String) -> Target? {
    let pieces = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let kind = pieces[0]
    guard kind == "password" || kind == "username" || kind == "present" else { return nil }
    guard pieces.count == 2 else { return Target(kind: kind, username: nil, password: nil) }
    let boxes = pieces[1].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    return Target(kind: kind, username: rect(boxes.first ?? ""), password: boxes.count > 1 ? rect(boxes[1]) : nil)
  }

  private static func rect(_ text: String) -> CGRect? {
    let numbers = text.split(separator: ",").compactMap { Double($0) }
    guard numbers.count == 4, numbers[2] >= 2, numbers[3] >= 2 else { return nil }
    return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
  }
}

enum PasswordFillScript {
  // Fills only the login fields of the page that was already verified to be
  // the same origin as the credential request. It never submits the form.
  // A username-only step has no password field, so it fills the username and
  // still reports "filled" instead of dropping the credential. Same-origin
  // frames are searched; a cross-origin frame throws or returns nothing and
  // is skipped, so a credential is never written into a frame Comet cannot
  // verify belongs to this page.
  static func source(username: String, password: String, moveFocus: Bool = true) -> String {
    let focusName = moveFocus ? "name.focus();\n        " : ""
    let focusField = moveFocus ? "field.focus();\n      " : ""
    return """
    (() => {
      const username = \(json(username));
      const password = \(json(password));
      const docs = [document];
      try {
        const frames = (typeof document.querySelectorAll === "function") ? document.querySelectorAll("iframe") : [];
        for (let i = 0; i < frames.length; i++) {
          try {
            const inner = frames[i].contentDocument;
            if (inner && inner.querySelector) docs.push(inner);
          } catch (e) {}
        }
      } catch (e) {}
      const find = (selector) => {
        for (let i = 0; i < docs.length; i++) {
          const found = docs[i].querySelector ? docs[i].querySelector(selector) : null;
          if (found) return {el: found, doc: docs[i]};
        }
        return null;
      };
      const passEntry = find('input[type="password"]');
      const field = passEntry ? passEntry.el : null;
      const strict = 'input[autocomplete="username"], input[type="email"], input[name="username" i]';
      let nameEntry = null;
      if (passEntry) {
        const scope = passEntry.el.form || passEntry.doc;
        nameEntry = scope.querySelector ? {el: scope.querySelector(strict), doc: passEntry.doc} : null;
        if (!nameEntry || !nameEntry.el) nameEntry = find(strict);
      } else {
        nameEntry = find(strict);
      }
      let name = nameEntry ? nameEntry.el : null;
      if (!name && passEntry) {
        const scope = passEntry.el.form || passEntry.doc;
        name = scope.querySelector ? scope.querySelector('input[type="text"]') : null;
      }
      if (name && username) {
        \(focusName)name.value = username;
        name.dispatchEvent(new Event("input", {bubbles:true}));
        name.dispatchEvent(new Event("change", {bubbles:true}));
      }
      if (field && password) {
        \(focusField)field.value = password;
        field.dispatchEvent(new Event("input", {bubbles:true}));
        field.dispatchEvent(new Event("change", {bubbles:true}));
      }
      if (!field && !name) return "no-password-field";
      return (name && username) || (field && password) ? "filled" : "no-password-field";
    })()
    """
  }

  private static func json(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text]),
      var encoded = String(data: data, encoding: .utf8), encoded.count >= 2
    else { return "\"\"" }
    encoded.removeFirst()
    encoded.removeLast()
    return encoded
  }
}

enum PasskeyEntitlement {
  static let key = "com.apple.developer.web-browser.public-key-credential"

  static var isPresent: Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    return (value as? Bool) == true
  }
}

enum PasskeyAuthorization: Equatable, Sendable {
  case authorized, denied, notDetermined, unavailable

  var title: String {
    switch self {
    case .authorized: "Allowed"
    case .denied: "Denied"
    case .notDetermined: "Not asked"
    case .unavailable: "Unavailable"
    }
  }

  static func map(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) -> Self {
    switch state {
    case .authorized: .authorized
    case .denied: .denied
    case .notDetermined: .notDetermined
    @unknown default: .unavailable
    }
  }
}

enum PasskeyAccess {
  static func current() -> PasskeyAuthorization {
    PasskeyAuthorization.map(ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials)
  }

  static func request() async -> PasskeyAuthorization {
    await withCheckedContinuation { continuation in
      ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { state in
        continuation.resume(returning: PasskeyAuthorization.map(state))
      }
    }
  }

  static var deviceConfigured: Bool? {
    if #available(macOS 26.2, *) {
      return ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys
    }
    return nil
  }
}

@MainActor
final class SystemPasswordFill: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
  static let shared = SystemPasswordFill()
  private var controller: ASAuthorizationController?
  private var tab: UUID?
  private var page: URL?
  private var onFinish: ((String) -> Void)?
  private var report: ((String) -> Void)?
  private var suggestions = false

  var isRequestOpen: Bool { controller != nil }

  func start(tab: UUID, url: URL, finish: @escaping (String) -> Void) {
    begin(tab: tab, url: url, suggestions: false, completion: finish)
  }

  // Focus-triggered path. Prefer credentials already on this Mac so the system UI behaves like a suggestion.
  func suggest(tab: UUID, url: URL) async {
    guard CredentialPage.origin(url) != nil, controller == nil else { return }
    if AgentActivity.shared.phase == .executing { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      begin(tab: tab, url: url, suggestions: true) { _ in
        continuation.resume()
      }
    }
  }

  func cancel(tab: UUID) {
    guard self.tab == tab else { return }
    cancel()
  }

  func cancel() {
    controller?.cancel()
  }

  private func begin(tab: UUID, url: URL, suggestions: Bool, completion: @escaping (String) -> Void) {
    if let refusal = PasswordFillDecision.canRequest(privateTab: Engine.shared.incognitoTabs.contains(tab), url: url) {
      completion(refusal)
      return
    }
    guard controller == nil else {
      completion(PasswordAutofillPolicy.busy)
      return
    }
    self.tab = tab
    page = url
    self.suggestions = suggestions
    onFinish = completion
    let request = ASAuthorizationPasswordProvider().createRequest()
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    self.controller = controller
    if suggestions {
      controller.performRequests(options: .preferImmediatelyAvailableCredentials)
    } else {
      controller.performRequests()
    }
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    if let tab {
      let host = NSApp.windows.first { window in
        guard let store = (window.windowController as? WindowController)?.store else { return false }
        return store.spaces.spaces.contains { space in space.tabs.contains { $0.id == tab } }
      }
      if let host { return host }
    }
    return NSApp.keyWindow ?? ASPresentationAnchor()
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
    let finish = onFinish
    guard let credential = authorization.credential as? ASPasswordCredential else {
      finish?("macOS did not return a password.")
      clear()
      return
    }
    guard let tab, let page, let contents = Engine.shared.tabs[tab] else {
      finish?("The page changed, so the password was not filled.")
      clear()
      return
    }
    if let refusal = PasswordFillDecision.canApply(requested: page, current: contents.url) {
      finish?(refusal)
      clear()
      return
    }
    let script = PasswordFillScript.source(username: credential.user, password: credential.password)
    report = finish
    clear()
    contents.evaluateJavaScript(script) { result in
      let filled = result == "filled"
      Task { @MainActor in
        SystemPasswordFill.shared.finishFill(filled)
      }
    }
  }

  private func finishFill(_ filled: Bool) {
    let message = filled ? "Filled the password field. The form was not submitted." : "This page has no password field."
    report?(message)
    report = nil
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
    let quiet = suggestions
    let code = (error as NSError).code
    if quiet {
      finish(code == ASAuthorizationError.canceled.rawValue ? "Canceled." : "")
    } else if code == ASAuthorizationError.canceled.rawValue {
      finish("Canceled.")
    } else {
      finish("macOS did not provide a password for this page.")
    }
  }

  private func finish(_ message: String) {
    let callback = onFinish
    clear()
    callback?(message)
  }

  private func clear() {
    controller = nil
    tab = nil
    page = nil
    onFinish = nil
    suggestions = false
  }
}

// Chromium draws the page, so macOS will not attach Password AutoFill to those inputs.
// Native username and password fields, with the system content types, sit over the login
// controls. Suggestions come from macOS. Comet never reads the Passwords database.
@MainActor
final class PasswordAutoFillHost: NSObject, NSTextFieldDelegate {
  static let shared = PasswordAutoFillHost()
  private let username = NSTextField(frame: .zero)
  private let password = NSSecureTextField(frame: .zero)
  private var tab: UUID?
  private var page: URL?
  private var suppress = false
  private var configured = false

  func update(tab: UUID, url: URL, target: PasswordFieldGeometry.Target) {
    guard CredentialPage.origin(url) != nil, !Engine.shared.incognitoTabs.contains(tab),
      let web = Engine.shared.tabs[tab]?.view, let content = web.window?.contentView
    else {
      dismiss(tab: tab)
      return
    }
    configure()
    self.tab = tab
    page = url
    place(username, rect: target.username, web: web, content: content)
    place(password, rect: target.password, web: web, content: content)
    guard let window = web.window, window.isKeyWindow else { return }
    if target.kind == "password", password.superview != nil, !isEditing(password, in: window) {
      window.makeFirstResponder(password)
    } else if target.kind == "username", username.superview != nil, !isEditing(username, in: window), !isEditing(password, in: window) {
      window.makeFirstResponder(username)
    }
  }

  func dismiss(tab: UUID) {
    guard self.tab == nil || self.tab == tab else { return }
    let window = username.window ?? password.window
    if let window, isEditing(username, in: window) || isEditing(password, in: window) {
      window.makeFirstResponder(nil)
    }
    suppress = true
    username.stringValue = ""
    password.stringValue = ""
    suppress = false
    username.removeFromSuperview()
    password.removeFromSuperview()
    self.tab = nil
    page = nil
  }

  func controlTextDidChange(_ notification: Notification) {
    guard !suppress, let tab, let page, let contents = Engine.shared.tabs[tab], let current = contents.url,
      CredentialPage.sameOrigin(page, current)
    else { return }
    let user = text(of: username)
    let secret = text(of: password)
    guard !user.isEmpty || !secret.isEmpty else { return }
    let script = PasswordFillScript.source(username: user, password: secret, moveFocus: false)
    contents.evaluateJavaScript(script) { _ in }
  }

  private func text(of field: NSTextField) -> String {
    if let editor = field.currentEditor() { return editor.string }
    return field.stringValue
  }

  private func configure() {
    guard !configured else { return }
    configured = true
    username.contentType = .username
    password.contentType = .password
    for field in [username, password as NSTextField] {
      field.delegate = self
      field.isBordered = false
      field.isBezeled = false
      field.drawsBackground = false
      field.backgroundColor = .clear
      field.font = .systemFont(ofSize: 13)
      field.textColor = .labelColor
      field.focusRingType = .none
      field.lineBreakMode = .byClipping
      field.cell?.wraps = false
      field.cell?.isScrollable = true
    }
    username.placeholderString = ""
    username.setAccessibilityLabel("Username")
    password.setAccessibilityLabel("Password")
  }

  private func place(_ field: NSTextField, rect: CGRect?, web: NSView, content: NSView) {
    guard let rect else {
      field.isHidden = true
      return
    }
    var local = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    if !web.isFlipped {
      local.origin.y = web.bounds.height - rect.origin.y - rect.height
    }
    let inWindow = web.convert(local, to: nil)
    field.frame = content.convert(inWindow, from: nil)
    field.isHidden = false
    if field.superview !== content { content.addSubview(field) }
  }

  private func isEditing(_ field: NSTextField, in window: NSWindow) -> Bool {
    window.firstResponder === field || window.firstResponder === field.currentEditor()
  }
}

@MainActor
final class PasswordFieldMonitor {
  static let shared = PasswordFieldMonitor()

  func watch(token: String) async {
    guard token != "hidden", token != "none" else { return }
    let id = String(token.prefix(36))
    guard let tab = UUID(uuidString: id), token.count > 37 else { return }
    let raw = String(token.dropFirst(37))
    guard let url = URL(string: raw) else { return }
    await watch(tab: tab, url: url)
  }

  func watch(tab: UUID, url: URL) async {
    defer {
      SystemPasswordFill.shared.cancel(tab: tab)
      PasswordAutoFillHost.shared.dismiss(tab: tab)
    }
    guard CredentialPage.origin(url) != nil else { return }
    while !Task.isCancelled {
      if AgentActivity.shared.phase == .executing || AgentActivity.shared.phase == .verifying {
        PasswordAutoFillHost.shared.dismiss(tab: tab)
        try? await Task.sleep(for: .milliseconds(400))
        continue
      }
      let page = Engine.shared.tabs[tab]?.url ?? url
      let raw = await probe(tab)
      if let target = PasswordFieldGeometry.parse(raw) {
        PasswordAutoFillHost.shared.update(tab: tab, url: page, target: target)
      } else {
        PasswordAutoFillHost.shared.dismiss(tab: tab)
      }
      // Security's save prompt: the monitor already polls this tab, so
      // the submit listener's pending credential is collected here
      // instead of a second polling loop. The macOS AutoFill host above
      // is untouched by this call.
      await CSecuritySaveIntegration.poll(tab: tab, pageURL: page)
      try? await Task.sleep(for: .milliseconds(350))
    }
  }

  private func probe(_ tab: UUID) async -> String {
    await withCheckedContinuation { continuation in
      guard let contents = Engine.shared.tabs[tab] else {
        continuation.resume(returning: "")
        return
      }
      contents.evaluateJavaScript(PasswordFieldProbe.script) { result in
        Task { @MainActor in
          continuation.resume(returning: result ?? "")
        }
      }
    }
  }
}

