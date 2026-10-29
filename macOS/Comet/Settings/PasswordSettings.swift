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

// The old PasswordsPane was replaced by CSecurityServiceUI
// (macOS/Comet/Security/CSecurityServiceUI.swift), which is the Passwords
// and Autofill pane. This file keeps only the shared policy constants and
// the fill decision used by the engine's macOS-provider path, so that
// path and Security do not each invent their own origin rules.
