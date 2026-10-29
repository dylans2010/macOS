import AppKit
import SwiftUI

// What Comet can actually use for passwords. Google Password Manager's sync is a Chrome-only
// service. This type never reports that service as connected.
enum PasswordAutofillPolicy {
  static let sectionTitle = "Passwords and Autofill"
  static let provider = "macOS Password AutoFill"
  static let googleSyncAvailable = false
  static let googleStatus = "Not available"
  static let googleManager = URL(string: "https://passwords.google.com/")!
  static let googleImportHelp = URL(string: "https://support.google.com/chrome/answer/13068232")!
  static let profilePasswords = URL(string: "chrome://password-manager/passwords")!

  static let storage = """
    Suggestions come from the credential provider you turned on in System Settings → General → AutoFill & Passwords. \
    Comet does not read that provider’s files. A password is written into the page only after you choose it, and the form is not submitted.
    """

  static let googleLimitation = """
    Google Password Manager is not connected. Signing in to a Google account on a website does not give Comet that account’s passwords. \
    Google’s password sync is part of Chrome, and Google does not offer it to other Chromium browsers. \
    Comet also cannot ask Google Password Manager for a login, because Google does not provide a Mac credential-provider extension for other browsers.
    """

  static let csvWarning = """
    A password CSV is a text file. Anyone who opens it can read every password in it. \
    Do not email it, upload it, or leave it in Downloads. Delete it after you finish importing.
    """

  static let importSteps = [
    "Export the CSV yourself from the password manager you use now. Comet will not open another app’s database or copy its passwords into a Google account.",
    "Sign in at Google Password Manager in Chrome, or at passwords.google.com, with the Google account that should keep the passwords.",
    "Use that site’s import control and select the CSV. Google’s help page describes the file it accepts. Comet cannot run Chrome’s importer.",
    "On passwords.google.com, confirm the logins are in that account. They stay there. They do not start appearing in Comet.",
    "To fill a login in Comet, the password has to be offered by a provider macOS can use, such as the Passwords app. Importing into Google Password Manager does not do that.",
  ]

  static let profileStore = """
    Passwords you import with Comet’s import window are saved in this profile’s own store. \
    That store is not Google Password Manager and it is not synced to a Google account. \
    The login-field suggestions Comet shows are still the macOS ones.
    """

  // The second half of the migration, and the part the Google-only guide
  // leaves out: importing into Google does not make a password fill in
  // Comet. This is a separate, explicit copy into the macOS provider, not
  // a sync, and it is the only way a Google-saved password fills here.
  static let macOSImportNote = """
    Importing into Google Password Manager does not fill a login in Comet. \
    To fill a Google-saved password here, copy it into the provider macOS uses. \
    That copy is not a sync: later changes in Google will not appear in Comet, \
    and logins saved through the macOS provider will not go to Google.
    """

  static let macOSImportSteps = [
    "Export a CSV yourself from Google Password Manager, following Google’s help. Comet does not export it for you, and it never uploads the file anywhere.",
    "On macOS Sequoia or later, open the Passwords app and choose File > Import Passwords from File, then choose the CSV. Menu wording varies by macOS version. Review the entries it could not import; imported passwords do not replace entries you already have.",
    "In System Settings → General → AutoFill & Passwords, turn on AutoFill and choose the provider that now holds those passwords.",
    "In Comet, focus a login field or use Test Autofill on this page, and choose the login. Canceling leaves the form unchanged, and nothing is submitted.",
    "Delete the CSV after importing. The Passwords app offers to delete it when the import finishes; do not leave a copy in Downloads.",
  ]

  static let privateWindow = "Private windows do not offer saved passwords."
  static let webOnly = "Passwords can only fill an http or https page."
  static let pageChanged = "The page changed, so the password was not filled."
  static let noPage = "Open an http or https login page in a normal window, then test again."
  static let busy = "A credential request is already open."

  static let passkeyNote = """
    A website’s passkey request is handled by Chromium and, when this build is allowed to, by the macOS passkey sheet. \
    Private keys stay in the system. Passkeys saved only in Google Password Manager inside Chrome are not available here.
    """
}

enum PasswordFillDecision {
  static func canRequest(privateTab: Bool, url: URL) -> String? {
    if privateTab { return PasswordAutofillPolicy.privateWindow }
    guard CredentialPage.origin(url) != nil else { return PasswordAutofillPolicy.webOnly }
    return nil
  }

  static func canApply(requested: URL, current: URL?) -> String? {
    guard let current, CredentialPage.sameOrigin(requested, current) else { return PasswordAutofillPolicy.pageChanged }
    return nil
  }
}

struct PasswordsPane: View {
  var openPage: (URL) -> Void = { NSWorkspace.shared.open($0) }
  @State private var passkeys = PasskeyAccess.current()
  @State private var status: String?
  @State private var showImport = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(PasswordAutofillPolicy.sectionTitle).font(.system(size: 13, weight: .semibold))
        labeled("Suggestion provider", PasswordAutofillPolicy.provider)
        labeled("Google Password Manager", PasswordAutofillPolicy.googleStatus)
        Text(PasswordAutofillPolicy.googleLimitation)
          .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text(PasswordAutofillPolicy.storage)
          .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Open Google Password Manager") { openPage(PasswordAutofillPolicy.googleManager) }
          Button("Import Instructions") { showImport = true }
          Button("Test Autofill on This Page", action: testFill)
        }
        Text("Test Autofill asks macOS for a password for the page in front. Canceling leaves the form unchanged. Nothing is submitted.")
          .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if showImport { importGuide }
        Text("This profile").font(.system(size: 13, weight: .semibold)).padding(.top, 4)
        Text(PasswordAutofillPolicy.profileStore)
          .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button("Review Passwords Saved in This Profile") { openPage(PasswordAutofillPolicy.profilePasswords) }
        Text("Passkeys").font(.system(size: 13, weight: .semibold)).padding(.top, 4)
        Text(passkeyExplanation).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        labeled("This build", PasskeyEntitlement.isPresent ? "Signed for passkeys" : "Not signed for passkeys")
        labeled("macOS access", passkeys.title)
        if let configured = PasskeyAccess.deviceConfigured {
          labeled("This Mac", configured ? "Passkeys are set up" : "Passkeys are not set up")
        }
        Button("Ask macOS to Allow Passkeys", action: request)
        if let status {
          Text(status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Autofill result")
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var importGuide: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Import into Google Password Manager")
        .font(.system(size: 13, weight: .semibold))
      Text(PasswordAutofillPolicy.csvWarning)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(Array(PasswordAutofillPolicy.importSteps.enumerated()), id: \.offset) { index, step in
        Text("\(index + 1). \(step)")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Google’s Import Help") { openPage(PasswordAutofillPolicy.googleImportHelp) }
      Text("Fill those passwords in Comet")
        .font(.system(size: 13, weight: .semibold))
        .padding(.top, 4)
      Text(PasswordAutofillPolicy.macOSImportNote)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(Array(PasswordAutofillPolicy.macOSImportSteps.enumerated()), id: \.offset) { index, step in
        Text("\(index + 1). \(step)")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
  }

  private var passkeyExplanation: String {
    if PasskeyEntitlement.isPresent {
      PasswordAutofillPolicy.passkeyNote
    } else {
      "Developer and unsigned builds omit Apple’s web-browser passkey entitlement, so macOS will not let this copy use iCloud passkeys. A signed release presents the system sheet. Comet does not invent passkey responses. " + PasswordAutofillPolicy.passkeyNote
    }
  }

  private func labeled(_ title: String, _ value: String) -> some View {
    LabeledContent(title) { Text(value) }
      .font(.system(size: 12))
  }

  private func request() {
    Task {
      passkeys = await PasskeyAccess.request()
      status = passkeys == .authorized ? "macOS allowed passkey access." : "macOS did not allow passkey access (\(passkeys.title))."
    }
  }

  private func testFill() {
    guard let tab = FrontBrowser.tabID, let url = FrontBrowser.url else {
      status = PasswordAutofillPolicy.noPage
      return
    }
    SystemPasswordFill.shared.start(tab: tab, url: url) { message in
      status = message.isEmpty ? PasswordAutofillPolicy.noPage : message
    }
  }
}
