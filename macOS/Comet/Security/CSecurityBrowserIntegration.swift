import AppKit
import Foundation
import SwiftUI

// Browser integration for Security, over the engine Comet actually has.
//
// Engine facts (see Settings/PASSWORDS_AUTOFILL.md):
// - Chromium 156 as EngineCore, no Chrome browser window, so there is
//   no Chrome password-save bubble to host. Page UI is replaced by the
//   shell through the bridge.
// - Swift reaches a page only by polling ECWebContents.evaluateJavaScript,
//   which runs in Chromium's isolated world (ISOLATED_WORLD_ID_CHROME_INTERNAL)
//   and returns a single string. There is no renderer-to-browser message
//   channel in this embedder.
// - Therefore login detection here is pull-based, and the save listener
//   below stores a pending credential in an isolated-world global —
//   page scripts in the main world cannot read isolated-world globals —
//   until the next poll retrieves and clears it. If the document is
//   destroyed before that poll (an instant same-document navigation
//   that wipes the world), the save is missed rather than guessed at.
//   That limitation is documented in SECURITY.md; it is not papered
//   over by reading field values on every poll (the probe deliberately
//   never reads values).
//
// What this file does, and does not do:
// - It never fills a credential without (a) an explicit user selection
//   in the picker, (b) successful service authentication, and (c) a
//   fresh same-origin check against the tab's CURRENT url at fill time.
// - It never submits a form. PasswordFillScript writes values and
//   dispatches input/change events only.
// - It never writes a credential into a cross-origin frame: the fill
//   script searches same-origin frames only (its contentDocument access
//   throws for cross-origin frames and those are skipped).
// - Private (incognito) tabs never offer Security credentials.
enum CSecuritySaveScript {
  /// Installs a submit listener once per document. On submit it captures
  /// the submitted form's username and password values into an
  /// isolated-world global and leaves the submission alone (no
  /// preventDefault, no interception of the response).
  static let install = """
    (() => {
      if (globalThis.__cometSecuritySaveInstalled) return "installed";
      globalThis.__cometSecuritySaveInstalled = true;
      globalThis.__cometSecurityPending = null;
      const capture = (form) => {
        try {
          if (!form) return;
          const pass = form.querySelector('input[type="password"]');
          if (!pass || !pass.value) return;
          const user = form.querySelector('input[autocomplete="username"], input[type="email"], input[name="username" i], input[type="text"]');
          globalThis.__cometSecurityPending = JSON.stringify({
            username: user ? user.value : "",
            password: pass.value
          });
        } catch (e) {}
      };
      document.addEventListener("submit", (event) => {
        const form = event.target && event.target.tagName === "FORM" ? event.target : null;
        capture(form);
      }, true);
      // Many sites never fire a form submit: they log in with a button
      // click + fetch, or a single-page-app transition. Capturing on
      // a submit-button click covers those logins too. The values are
      // only captured at a user action (submit or click), never by
      // polling field values, so the probe's no-value-reading rule
      // is unchanged. A login that then fails validation may still
      // prompt; choosing Not Now saves nothing.
      document.addEventListener("click", (event) => {
        const target = event.target && event.target.closest
          ? event.target.closest('button, input[type="submit"], input[type="image"]')
          : null;
        if (!target) return;
        const form = target.form || (target.closest ? target.closest("form") : null);
        capture(form);
      }, true);
      return "installed";
    })()
    """

  /// Returns the pending submission as JSON and clears it, or "" when
  /// there is none. Retrieving clears: one submission prompts at most
  /// once, even if the user answers "Not Now".
  static let takePending = """
    (() => {
      const pending = globalThis.__cometSecurityPending || null;
      globalThis.__cometSecurityPending = null;
      return pending ? pending : "";
    })()
    """

  /// A pending submission decoded without ever logging it.
  struct Pending: Decodable, Sendable {
    var username: String
    var password: String
  }

  static func decode(_ raw: String) -> Pending? {
    guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Pending.self, from: data)
  }
}

// Poll-side save detection, driven from PasswordFieldMonitor.watch.
// Kept separate from the monitor so the monitor's macOS-AutoFill path
// is untouched and this path can be reasoned about (and tested) alone.
@MainActor
enum CSecuritySaveIntegration {
  /// One install key per tab + origin. This used to be a single
  /// String, so two monitored tabs took turns overwriting it: each
  /// poll re-installed and returned early, and neither tab ever
  /// reached takePending. A set fixes that without a second loop.
  private static var installedFor: Set<String> = []

  /// Installs the listener for this tab/origin (once per origin change)
  /// and, if a submission is pending, offers the native save alert.
  /// Returns after the alert is dismissed; the monitor loop resumes
  /// afterwards. Nothing is saved without the user choosing Save.
  static func poll(tab: UUID, pageURL: URL) async {
    guard !Engine.shared.incognitoTabs.contains(tab),
      let origin = CredentialPage.origin(pageURL),
      let contents = Engine.shared.tabs[tab]
    else { return }
    // Prepare BEFORE taking the pending submission. The old order
    // took (and cleared) the pending value first, then
    // presentSaveAlert returned silently when the vault was not ready
    // — a locked vault therefore lost the login with no UI at all.
    // Now a not-ready vault leaves the pending value in place for
    // the next poll, after the user unlocks Security.
    let service = CSecurityService.shared
    if !service.isVaultReady { service.prepare() }
    guard service.isVaultReady else { return }
    let installKey = tab.uuidString + "|" + origin
    if !installedFor.contains(installKey) {
      installedFor.insert(installKey)
      contents.evaluateJavaScript(CSecuritySaveScript.install) { _ in }
      return
    }
    let raw = await evaluate(tab: tab, script: CSecuritySaveScript.takePending)
    guard let pending = CSecuritySaveScript.decode(raw), !pending.password.isEmpty else { return }
    // Re-verify the origin at prompt time: the page may have navigated
    // since the form was submitted.
    let current = Engine.shared.tabs[tab]?.url ?? pageURL
    guard CredentialPage.sameOrigin(pageURL, current),
      let credential = CSecurityCredential.make(
        url: origin, username: pending.username, password: pending.password)
    else { return }
    presentSaveAlert(pageURL: current, credential: credential)
  }

  private static func evaluate(tab: UUID, script: String) async -> String {
    await withCheckedContinuation { continuation in
      guard let contents = Engine.shared.tabs[tab] else {
        continuation.resume(returning: "")
        return
      }
      contents.evaluateJavaScript(script) { result in
        Task { @MainActor in continuation.resume(returning: result ?? "") }
      }
    }
  }

  /// The native "Save password to Security?" alert. The website and
  /// username are shown; the password is never displayed in the alert.
  static func presentSaveAlert(pageURL: URL, credential: CSecurityCredential) {
    let service = CSecurityService.shared
    if !service.isVaultReady { service.prepare() }
    guard service.isVaultReady else {
      // Second line of defence for a vault that locked between the
      // poll and the alert: say so, instead of silently dropping
      // the save the user just submitted.
      let locked = NSAlert()
      locked.messageText = "Security could not be opened"
      locked.informativeText = "Open Settings → Passwords and Autofill and tap Unlock Security, then submit the login again. Nothing was saved."
      locked.addButton(withTitle: "OK")
      locked.runModal()
      return
    }
    // An existing credential for this origin + username is not replaced
    // silently: the alert below is the explicit confirmation, and only
    // a Save choice reaches saveSubmitted, which then replaces it.
    let exists = (try? service.metadata(forOrigin: credential.origin))?.contains(where: { $0.username == credential.username }) == true
    let alert = NSAlert()
    alert.messageText = "Save password to Security?"
    alert.informativeText = exists
      ? "Update the saved login for \(credential.origin) (\(credential.username)) in Security? It will be encrypted on this Mac."
      : "Save the login for \(credential.origin) (\(credential.username)) in Security? It will be encrypted on this Mac."
    alert.addButton(withTitle: "Save Password")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try service.saveSubmitted(credential)
    } catch {
      let failure = NSAlert()
      failure.messageText = "Could not save password to Security"
      failure.informativeText = "The vault could not be written. Nothing was saved."
      failure.runModal()
    }
  }
}

// Automatic fill offer, driven from PasswordFieldMonitor.watch.
//
// Until now the fill picker only appeared when the user already knew
// to run Fill Password (menu) or Fill on This Page (Settings). A login
// page with a focused password field showed only the macOS AutoFill
// overlay — a different store — so a Security login the user already
// had never surfaced, and it looked like "the popup does not show".
// This offer runs when the password field is actually focused
// (probe kind "password"), once per tab + origin, and only when
// Security holds a match for that origin. If Security holds nothing,
// it does nothing and the macOS path is untouched. A cancelled picker
// is not re-offered on the same page; a new origin gets a fresh offer.
@MainActor
enum CSecurityFillSuggestion {
  private static var offeredFor: Set<String> = []

  static func offerIfNeeded(tab: UUID, url: URL, kind: String) async {
    guard kind == "password", !Engine.shared.incognitoTabs.contains(tab),
      let origin = CredentialPage.origin(url)
    else { return }
    let key = tab.uuidString + "|" + origin
    guard !offeredFor.contains(key) else { return }
    let service = CSecurityService.shared
    if !service.isVaultReady { service.prepare() }
    guard service.isVaultReady,
      let matches = try? service.metadata(forPageURL: url), !matches.isEmpty
    else { return }
    // Mark before presenting: the monitor polls every 350 ms, and
    // without this a second picker would stack while the first is open.
    offeredFor.insert(key)
    _ = await CSecurityAutofillFlow.fill(tab: tab, url: url)
  }
}

// The Security-first autofill flow: picker -> authentication -> fresh
// origin recheck -> fill. Used by the Fill Password menu action and by
// the Security settings "Fill on This Page" button.
@MainActor
enum CSecurityAutofillFlow {
  enum Outcome: Sendable {
    case filled(username: String)
    case noSecurityMatches
    case cancelled
    case failed(String)
  }

  /// Fills the selected tab's login form from Security. Returns
  /// .noSecurityMatches when Security holds nothing for this origin, so
  /// the caller can fall back to the macOS provider path (the previous
  /// behaviour) instead of showing an empty picker.
  static func fill(tab: UUID, url: URL) async -> Outcome {
    if let refusal = PasswordFillDecision.canRequest(
      privateTab: Engine.shared.incognitoTabs.contains(tab), url: url)
    {
      return .failed(refusal)
    }
    let service = CSecurityService.shared
    if !service.isVaultReady { service.prepare() }
    guard service.isVaultReady else { return .failed("Security is not ready.") }
    guard let matches = try? service.metadata(forPageURL: url), !matches.isEmpty else {
      return .noSecurityMatches
    }
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
      return .failed("No browser window is available.")
    }
    let chosen: CSecurityCredential.Metadata? = await withCheckedContinuation { continuation in
      var resumed = false
      let resumeOnce: (CSecurityCredential.Metadata?) -> Void = { value in
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
      }
      let authPromise = service.authPolicy.promise
      presentModal(over: window) { dismiss in
        CSecurityAccountPicker(
          origin: CredentialPage.origin(url) ?? url.host() ?? url.absoluteString,
          authPromise: authPromise,
          accounts: matches,
          onChoose: { account in dismiss(); resumeOnce(account) },
          onCancel: { dismiss(); resumeOnce(nil) })
      }
    }
    guard let chosen else { return .cancelled }
    // Authentication BEFORE the password is released, and the origin
    // again at the moment of filling — not only when the picker opened.
    let result = await service.password(
      for: chosen.id, reason: "Fill the saved password for \(chosen.origin).")
    switch result {
    case .failure(.authenticationCancelled):
      return .cancelled
    case .failure:
      return .failed("Security could not release that password.")
    case .success(let password):
      guard let contents = Engine.shared.tabs[tab], let current = contents.url,
        CredentialPage.sameOrigin(url, current)
      else { return .failed(PasswordAutofillPolicy.pageChanged) }
      let filled = await evaluateFilled(tab: tab, username: chosen.username, password: password)
      return filled ? .filled(username: chosen.username) : .failed("This page has no password field.")
    }
  }

  private static func evaluateFilled(tab: UUID, username: String, password: String) async -> Bool {
    await withCheckedContinuation { continuation in
      guard let contents = Engine.shared.tabs[tab] else {
        continuation.resume(returning: false)
        return
      }
      contents.evaluateJavaScript(PasswordFillScript.source(username: username, password: password)) { result in
        Task { @MainActor in continuation.resume(returning: result == "filled") }
      }
    }
  }
}

// The account picker shown before any password is released. It lists
// usernames and display names only — never passwords — so the user can
// see exactly which account is about to fill.
struct CSecurityAccountPicker: View {
  var origin: String
  var authPromise: String
  var accounts: [CSecurityCredential.Metadata]
  var onChoose: (CSecurityCredential.Metadata) -> Void
  var onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Fill password from Security?").font(.system(size: 14, weight: .semibold))
      Text("Choose an account for \(origin). You will be asked to confirm with \(authPromise) before the password is filled. The form will not be submitted.")
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(accounts) { account in
        Button {
          onChoose(account)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(account.username).font(.system(size: 13, weight: .medium))
            if let displayName = account.displayName, !displayName.isEmpty {
              Text(displayName).font(.system(size: 12)).foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
      }
      Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
    }
    .padding(20)
    .frame(width: 360)
  }
}
