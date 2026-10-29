import AppKit
import AuthenticationServices
import Foundation
import Security
import SwiftUI

enum CredentialPage {
  static func origin(_ url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
      let host = url.host()?.lowercased(), !host.isEmpty, !host.contains(" ")
    else { return nil }
    return "\(scheme)://\(host)"
  }

  static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
    guard let a = origin(left), let b = origin(right) else { return false }
    return a == b
  }
}

enum PasswordFillScript {
  static func source(username: String, password: String) -> String {
    """
    (() => {
      const username = \(json(username));
      const password = \(json(password));
      const field = document.querySelector('input[type="password"]');
      if (!field) return "no-password-field";
      const root = field.form || document;
      const name = root.querySelector('input[autocomplete="username"], input[type="email"], input[name="username" i], input[type="text"]');
      if (name && username) {
        name.focus();
        name.value = username;
        name.dispatchEvent(new Event("input", {bubbles:true}));
        name.dispatchEvent(new Event("change", {bubbles:true}));
      }
      field.focus();
      field.value = password;
      field.dispatchEvent(new Event("input", {bubbles:true}));
      field.dispatchEvent(new Event("change", {bubbles:true}));
      return "filled";
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

  func start(tab: UUID, url: URL, finish: @escaping (String) -> Void) {
    guard CredentialPage.origin(url) != nil else {
      finish("Passwords can only fill an http or https page.")
      return
    }
    guard controller == nil else {
      finish("A credential request is already open.")
      return
    }
    self.tab = tab
    page = url
    onFinish = finish
    let request = ASAuthorizationPasswordProvider().createRequest()
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    self.controller = controller
    controller.performRequests()
  }

  func cancel() {
    controller?.cancel()
    clear()
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    NSApp.keyWindow ?? ASPresentationAnchor()
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
    let finish = onFinish
    guard let credential = authorization.credential as? ASPasswordCredential else {
      finish?("macOS did not return a password.")
      clear()
      return
    }
    guard let tab, let page, let contents = Engine.shared.tabs[tab], let current = contents.url,
      CredentialPage.sameOrigin(page, current)
    else {
      finish?("The page changed, so the password was not filled.")
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
    let finish = onFinish
    clear()
    let code = (error as NSError).code
    if code == ASAuthorizationError.canceled.rawValue {
      finish?("Canceled.")
    } else {
      finish?("macOS did not provide a password for this page.")
    }
  }

  private func clear() {
    controller = nil
    tab = nil
    page = nil
    onFinish = nil
  }
}

struct PasswordsPane: View {
  @State private var passkeys = PasskeyAccess.current()
  @State private var status: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Passkeys").font(.system(size: 13, weight: .semibold))
        Text(passkeyExplanation).font(.system(size: 12)).foregroundStyle(.secondary)
        LabeledContent("This build") { Text(PasskeyEntitlement.isPresent ? "Signed for passkeys" : "Not signed for passkeys") }
        LabeledContent("macOS access") { Text(passkeys.title) }
        if let configured = PasskeyAccess.deviceConfigured {
          LabeledContent("This Mac") { Text(configured ? "Passkeys are set up" : "Passkeys are not set up") }
        }
        Button("Ask macOS to Allow Passkeys", action: request)
        Text("Passwords").font(.system(size: 13, weight: .semibold)).padding(.top, 8)
        Text("Fill Password asks macOS to show its own credential sheet for the front window. Comet does not read the Passwords app’s files. The form is not submitted. Chromium still keeps passwords you import, in the profile’s password manager.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        if let status { Text(status).font(.system(size: 12)).foregroundStyle(.secondary) }
      }
      .padding(24)
    }
  }

  private var passkeyExplanation: String {
    if PasskeyEntitlement.isPresent {
      "A website’s passkey request is handled by Chromium and presented as the macOS passkey sheet on that tab’s window. Private keys stay in the system. Third-party providers appear there when macOS offers them."
    } else {
      "Developer and unsigned builds omit Apple’s web-browser passkey entitlement, so macOS will not let this copy use iCloud passkeys. A release signed with that entitlement presents the system sheet. Comet does not invent passkey responses."
    }
  }

  private func request() {
    Task {
      passkeys = await PasskeyAccess.request()
      status = passkeys == .authorized ? "macOS allowed passkey access." : "macOS did not allow passkey access (\(passkeys.title))."
    }
  }
}
