# Security in Comet — CSecurityService

This is the architecture report for Comet's first-party, local credential
manager, **Security**. It replaces the old PasswordsPane as the Passwords
and Autofill settings interface. It does not replace the macOS Password
AutoFill provider, Google Password Manager, passkeys, or the Chromium
profile store: those are separate stores, and the settings UI labels them
as such under "Other providers". See also `PASSWORDS_AUTOFILL.md` for the
macOS-provider path and the Google limitation.

## 1. What was audited (2026-10-28, at remote main 9ee4b30)

- Language/framework: Swift 6, SwiftUI + AppKit, macOS 15.0 deployment
  target, xcodegen (`project.yml` sources = `macOS/Comet`).
- Engine: Chromium 156.0.8078.48 as EngineCore (`//chrome` embedder,
  no Chrome browser window). Pages are reached from Swift only via
  `ECWebContents.evaluateJavaScript`, which runs in Chromium's isolated
  world and returns one string. There is no renderer-to-browser message
  channel in this embedder.
- Existing password pieces found: `Engine/SystemCredentials.swift`
  (macOS AutoFill host + system sheet, probe/fill scripts, port-aware
  origin matching), `Settings/PasswordSettings.swift` (policy + old
  PasswordsPane), `Import/LoginsReader.swift` + `ImportFeature`
  (Chromium profile import, including CSV into the profile store via
  `ECPassword.passwords(fromCSV:)`), `AI/AICredentials.swift` (AI API
  keys in the Keychain — unrelated, untouched).
- Info.plist: no `NSFaceIDUsageDescription` (correct: that key is iOS;
  macOS Touch ID via LocalAuthentication needs no usage-description
  key). Entitlements (`macOS/scripts/entitlements/app.plist`) were not
  weakened and no new entitlement was added: LocalAuthentication and
  the Keychain need none for this use, and no Keychain access group is
  set (the vault key is app-local, not shared).
- Tests: `CometTests/CredentialTests.swift` (origin, probe, fill,
  passkey mapping). No Swift toolchain exists in the Linux environment
  where this was written, so `xcodebuild` could not run here; see §9.

## 2. Architecture

Single authority: `CSecurityService` (`macOS/Comet/Security/`).
Everything else is a caller of it.

| File | Responsibility |
| --- | --- |
| `CSecurityCredential.swift` | The one credential model + strict origin matching + the migration converter from an already-decrypted `ImportedPassword`. |
| `CSecurityVault.swift` | AES-GCM vault envelope, Keychain key store, disk file store (with previous-good-copy backup), and the injectable-store `Store`. |
| `CSecurityService.swift` | Vault lifecycle, LA authentication + session, CRUD, CSV-import transaction, generated-password save/choice. |
| `CSecurityCSV.swift` | Pure CSV parsing, header mapping, row validation. No I/O. |
| `CSecurityPasswordGenerator.swift` | SecRandom-based generation, 8–12 configurable length, four-class guarantee, unbiased selection. |
| `CSecurityBrowserIntegration.swift` | Save-prompt scripts + alert, Security-first autofill flow + account picker. |
| `CSecurityServiceUI.swift` | The Passwords and Autofill pane, editor, CSV import preview, other-providers disclosure. |

No second password database, matcher, or generator exists for Security:
browser views, settings views, and login handlers all call the service.
`CredentialPage.origin` (from the existing engine path) is the shared
origin function, so Security and the macOS path cannot drift apart.

## 3. Vault encryption and Keychain protection

- File: `~/Library/Application Support/Comet/SecurityVault.json`
  (`Comet Debug` for Debug builds, via the existing `DataFolder` key),
  plus `SecurityVault.previous.json` as the last good copy.
- Contents: one JSON envelope, `{version: 1, sealedBox: base64}`.
  The sealed box is CryptoKit AES-GCM (AES-256) over a versioned JSON
  document of credentials. The file never contains a plaintext password
  (asserted by a test), and passwords are never written to UserDefaults,
  SQLite, logs, or debug files.
- Key: 32 bytes from `SecRandomCopyBytes`, stored as one Keychain
  generic-password item (`<bundle id>.security-vault-key`,
  account `vault-key-v1`), `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
  not synchronisable. No key or password is hardcoded.
- No master password in this version. Consequence, stated in the UI:
  deleting the Keychain item (or losing the Keychain) makes the vault
  permanently unreadable; there is nothing to reset. A future
  master-password mode would need a proper KDF (PBKDF2/Argon2 with a
  unique salt, never a plain hash) and a documented recovery story
  before being offered. The Secure Enclave is not claimed to store
  records; it does not.
- Writes are atomic (`.atomic`) with the previous copy preserved first.
  A damaged vault is never overwritten with an empty vault: loading a
  corrupt file throws `.vaultCorrupted`, leaves the file untouched, and
  tries the previous good copy once. Saving refuses before a successful
  load (`vaultNotLoaded`), so a failed load cannot become an empty save.
- Nothing is transmitted: no server, analytics, crash reporting, or AI
  service ever receives a credential, and no credential is logged.
  Temporary plaintext exists only in the vault operation that needs it;
  the generator's and vault's temporary key buffers are zeroed after use
  where the language allows (see the code comment on the limits of
  clearing managed buffers).

## 4. Authentication: Touch ID and fallback

- Policy is a user preference (non-secret, UserDefaults):
  - `system` (default): `LAContext` with
    `.deviceOwnerAuthentication` — Touch ID when available, device
    password otherwise. The UI says "Touch ID or your device password".
  - `biometricsOnly`: `.deviceOwnerAuthenticationWithBiometrics`.
    When biometrics are unavailable it fails with
    `.biometricsUnavailable`; it never silently falls back to a password.
    Only this policy's UI may say "Touch ID required".
- Authentication is enforced at the service boundary: `password(for:)`
  authenticates before returning a password. Metadata (origin,
  username, display name) needs no authentication, so the list and the
  picker can exist; a password never leaves the service unauthenticated.
- Sessions: a successful authentication lasts 5 minutes by default
  (`lockTimeout`, stored as a preference) and is reused within that
  window, so a user is not prompted per field. The origin is re-checked
  at fill time regardless of session validity.
- Lock: the UI's Lock button ends the session and purges the vault
  (key + credentials) from memory; the encrypted file and Keychain key
  stay, so Unlock reopens the vault. Inactivity alone ends the
  password-release session, not the list: that distinction is stated in
  code and in the UI, not blurred.
- No new Info.plist key, entitlement, or sandbox change was needed for
  macOS LocalAuthentication. `NSFaceIDUsageDescription` was deliberately
  NOT added (iOS-only key).

## 5. Login detection and origin verification

- Detection reuses the existing probe (`PasswordFieldProbe`): field
  types, `autocomplete` attributes, bounding boxes, same-origin iframe
  traversal, username-only multi-step steps. The probe never reads a
  field value.
- Save detection is new and pull-based, because the embedder offers no
  push channel: `CSecuritySaveScript.install` installs a submit listener
  in the isolated world. On submit it captures that form's username and
  password into an isolated-world global (page scripts in the main
  world cannot read isolated-world globals) and does not prevent the
  submission. The monitor's next poll retrieves and clears it, so one
  submission prompts at most once. The native `NSAlert` titled
  **"Save password to Security?"** shows the site and username, never
  the password, and offers **Save Password** / **Not Now**. Saving
  replaces an existing same-origin+username credential only after that
  explicit Save choice.
- Autofill: the Fill Password menu action and the settings "Fill on
  This Page" button are Security-first. If Security holds logins for
  the page's origin, a picker lists the accounts (usernames only) and
  the user chooses one; authentication runs; the tab's CURRENT url is
  re-checked for same origin; then `PasswordFillScript` writes the
  values and dispatches input/change events. The form is never
  submitted. If Security holds nothing for the origin, the flow falls
  back to the macOS provider path (previous behaviour); a cancelled
  picker does not fall through to a second system sheet. Private tabs
  never offer Security credentials.
- Matching is strict and exact: scheme + lowercased host +
  non-default port, compared as strings. No suffix matching, so
  `google.com` credentials never go to `google.example.com` or
  `google-login.example`, and no cross-origin frame is ever filled
  (the fill script skips frames whose `contentDocument` is
  inaccessible). A legitimate identity-provider redirect needs its own
  saved credential for that origin.

## 6. CSV import and password generation

- Import: NSOpenPanel (`.commaSeparatedText`), read locally, parsed by
  `CSecurityCSV` (quoted fields, doubled quotes, commas, multiline
  values, CRLF). Headers are auto-detected from Chrome/Safari/Firefox/
  1Password/Bitwarden/LastPass spellings (`name`, `url`, `username`,
  `email`, `password`, …); the preview lets the user remap any column,
  shows every row as import / already-saved duplicate / skipped-with-
  reason, and commits only on Import. Validation happens before the
  single vault write, so a failed write commits nothing. Multiple
  accounts for one site are preserved (different usernames); a
  same-origin+same-username row is a duplicate, not a second account.
  The source file is never deleted by Comet and never uploaded; the
  summary tells the user to delete it themselves.
- Generation: `SecRandomCopyBytes` with rejection sampling (no modulo
  bias), explicit character sets, at least one uppercase, one
  lowercase, one digit, one symbol, shuffled positions. The configured
  length is clamped to 8–12 (`Settings.length`); the generator itself
  requires ≥4 (one per class) so a future range expansion changes one
  constant. In the editor, Generate fills the field and saves the
  credential immediately (that invocation IS the user's consent — merely
  displaying a password never saves). If a same-origin+username
  credential exists, nothing is overwritten: the user chooses Replace
  or Keep Both as separate accounts. A failed save is reported as a
  failure, never claimed as saved.

## 7. What replaced what

- Replaced: the old `PasswordsPane` (removed from
  `PasswordSettings.swift`; the pane is now `CSecurityServiceUI` in
  `SettingsWindow`). Its policy constants and fill decision stay, as
  the shared rules for the macOS-provider path.
- Added (single implementation): vault, service, CSV, generator,
  browser save/autofill flow, settings UI, tests, this document.
- Retained deliberately, not duplicated: the macOS AutoFill host/sheet
  (external provider), the Chromium profile store and its import window
  (engine store, labelled as such), passkey handling (platform sheet),
  AI API-key Keychain helpers (unrelated secrets). None of these is a
  second Security vault, and none routes through a second matcher:
  Security matching lives in one place.
- Migration: there is no silent migration from the Chromium profile
  store, because its records are encrypted under that browser's Safe
  Storage key for a user-selected profile. The supported, user-
  controlled path is: export a CSV from
  `chrome://password-manager/passwords` (or from the previous manager)
  and import it into Security, or use `CSecurityMigration.credential`
  for an already-decrypted imported record. Migrated credentials are
  encrypted by the vault on save, like any other credential.

## 8. Tests

New: `macOS/CometTests/CSecurityTests.swift` (fake credentials only).
Covers vault round-trip, no-plaintext-in-file, corrupt-vault refusal,
previous-copy recovery, save-before-load refusal, strict origin
matching (including lookalike and port cases), bare-host normalisation,
CSV quoted/multiline/escaped/header-variant/malformed/unterminated
cases, transactional import on persistence failure, generation policy
across 8–12, settings clamping, generated-save no-silent-overwrite,
auth-session expiry, add/edit/delete (including origin move with
stable id), save-script non-submission, and the migration converter.
Existing `CredentialTests` still covers the probe/fill scripts and the
policy constants; nothing in it was weakened.

## 9. Verification status — read before release

- NOT runnable in the Linux environment where this was written: no
  Xcode, no macOS toolchain, no EngineCore framework. `xcodebuild
  test` was not run and is not claimed. The new files were added to
  `Comet.xcodeproj` (new `Security` group + test build file) and to
  `project.yml`'s source tree by directory, so `xcodegen generate`
  should reproduce them; verify the generated project still lists
  them before shipping.
- Static checks done here: brace/paren balance per new Swift file,
  no hardcoded key/password literals, no `print` of credentials, no
  `.submit`/`requestSubmit` in the save/fill scripts, no plaintext
  vault paths outside the vault file, and a Node harness re-check of
  the CSV grammar against the same cases as the Swift tests.
- Still unverified at runtime (must be done on a Mac):
  1. Build (`sh macOS/scripts/fetch-engine.sh`, `xcodegen generate`,
     Comet scheme) and run `CSecurityTests` + `CredentialTests`.
  2. Settings → Passwords and Autofill: add, search, edit, delete,
     lock/unlock, import a real CSV export you own, generate a
     password, and confirm the vault file on disk contains no
     plaintext password.
  3. Touch ID prompt on reveal/fill (both policies), cancellation,
     biometrics-unavailable fallback behaviour for `system`, and
     failure (not fallback) for `biometricsOnly`.
  4. On a real login page: Fill Password → picker → fill without
     submission; submit a new login → "Save password to Security?"
     → save → fill it back on a later visit; confirm no prompt on
     plain navigation and no prompt for a private window.
  5. Confirm a corrupted vault file is reported, not silently emptied,
     and that the previous-copy recovery works after a killed write.

## 10. Known limitations (honest, not placeholders)

- No auto-popup suggestion on field focus: this embedder has no Chrome
  bubble host, and an auto-modal would fight the macOS overlay fields.
  Security autofill is invoked (menu / settings button) and then shows
  a picker. Field-focus suggestion remains the macOS provider's overlay.
- Save detection requires a real form `submit` event in the main frame.
  Logins submitted via fetch/XHR without a submit event, and logins in
  cross-origin frames, will not prompt; the user can still add the
  login manually in Security settings.
- The isolated-world pending credential is lost if its document is
  destroyed before the next poll (~350 ms). That is a missed prompt,
  not a wrong fill.
- No master password, no sync, no recovery from a deleted Keychain
  item — by design in this version, and stated in the UI.
- Two windows sharing the single macOS overlay field pair, and the
  React/Vue native-setter issue in the fill script, are pre-existing
  macOS-path limitations from the earlier audit and are unchanged by
  this work (Security's fill uses the same `PasswordFillScript`).

## 11. 2026-10-28 follow-up: why the popup did not show, and what changed

Why it did not show (three separate causes, all in the old code):

1. Fill had no automatic popup at all. The picker only ran from
   Fill Password (menu) or Fill on This Page (Settings). On the page
   itself, the only overlay was the macOS AutoFill host — a different
   store. A Security login therefore never surfaced when a password
   field appeared, even though Security held it.
2. Save silently dropped a login when the vault was not ready.
   `CSecuritySaveIntegration.poll` took (and cleared) the pending
   submission, then `presentSaveAlert` returned without any UI when
   `isVaultReady` was false (vault locked after launch, or after
   Lock). No alert, no retry, and the submission was already gone.
   A second bug compounded it: `installedFor` was a single String,
   so two monitored tabs overwrote each other's install key and
   neither ever reached `takePending`.
3. Save only listened for a form `submit` event. Logins that use a
   button click + fetch, or a single-page-app transition, never
   fired it, so no pending value was ever captured.

What changed in this follow-up (same files, no new store):

- `CSecurityFillSuggestion.offerIfNeeded` (BrowserIntegration):
  when the password field is focused and Security holds a match for
  that origin, the Security picker is offered once per tab + origin.
  No match means no popup and the macOS path is untouched; a
  cancelled picker is not re-offered on the same page.
- Save poll now prepares the vault *before* taking the pending
  value, so a locked vault leaves the submission in place for the
  next poll, and `presentSaveAlert` shows a "Security could not be
  opened" alert instead of returning silently if the vault is still
  not ready. `installedFor` is now a per-tab+origin set.
- The save listener now also captures on a submit-button click,
  at that user action only. The probe still never reads field
  values by polling.
- Cache: `CSecurityVault.Store.load()` returns the in-memory
  credentials once loaded, without re-reading the disk or Keychain
  (Lock purges it; a failed load leaves it unloaded, so retries
  still re-read). `CSecurityService.prepare()` is a no-op when
  already ready, and `metadata()` is cached and cleared by every
  write path and by Lock. Plaintext passwords are still only held
  in the vault's existing in-memory store; no new copy is kept.
- Settings view is cleaner: shorter header text, one "Fill on This
  Page" button in the vault controls, a login count, and rows that
  show last-used only (no second modified-date line).

Superseded limitations from §10: the "no auto-popup" and "submit
event only" limitations above are now fixed for the main-frame,
focused-field and click cases. Cross-origin frames, a document
destroyed before the next poll, no master password, and no sync
remain as stated in §10. Still unverified on a Mac (same list as
§9, plus): focus a login page with a saved Security login and
confirm the picker appears once; submit a fetch-based login and
confirm the save prompt appears; lock Security, submit a login,
unlock, and confirm the prompt is not lost.
