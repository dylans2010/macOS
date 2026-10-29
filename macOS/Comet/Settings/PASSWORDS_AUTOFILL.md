# Passwords and Autofill in Comet

This is the architecture report for the Passwords and Autofill settings pane.
It separates what is verified in this codebase from what Google and Apple do
not offer to a third-party browser, so the settings UI never claims a
connection that does not exist.

## 1. Engine identified

- Comet embeds Chromium `156.0.8078.48` as `EngineCore.framework`
  (`engine/CHROMIUM_VERSION`, `engine/README.md`). It is not WKWebView,
  CEF, or a `content/`-only embedder.
- It builds Chrome's own framework target (`//chrome:chrome_framework`),
  renamed to EngineCore, and runs Chrome's full startup (`ChromeMain`,
  `ProfileManager`, prefs, the extension system) with `--no-startup-window`.
  The Swift shell creates web contents directly against a Chrome `Profile`.
- Every `ECWebContents` gets Chrome's tab helpers
  (`TabHelpers::AttachTabHelpers`), including autofill and password-manager
  clients. Chrome's UI code is linked but never instantiated, because there
  is no Chrome browser window: the password-save and translate bubbles
  therefore do not appear, and the shell replaces page UI (permissions,
  dialogs, context menu) through the bridge instead.
- Profiles are Chrome profiles managed by the engine
  (`macOS/Comet/Engine/Engine.swift`, `ec_browser_context.mm`). A Comet
  profile's own password store is Chromium's `password_store`, reached
  through `chrome://password-manager/passwords` and through
  `ECBrowserContext.importPasswords` (`engine/src/ec_logins.mm`). That store
  is local to the profile. It is not Google Password Manager and it is not
  synced to a Google account.

## 2. Decision gate: why there is no direct Google Password Manager integration

Google Password Manager's cloud-backed credential sync is a Chrome service,
not a Chromium component and not a public API for other browsers. Google
withdrew Chrome sync (bookmarks, history, passwords) from third-party
Chromium browsers, and signing into a Google account on a website in Comet
does not give Comet that account's passwords, passkeys, or sync state.
There is no supported macOS credential-provider extension from Google that
another browser can call, and Comet does not reverse-engineer private
Google endpoints, impersonate Chrome, read Chrome's private databases, or
use undocumented authentication mechanisms.

The supported fallback, and the one actually implemented, is:

1. **Google Password Manager as a web destination and import target.**
   Settings opens https://passwords.google.com/ and links Google's import
   help (https://support.google.com/chrome/answer/13068232). Importing
   there is done by the user in Chrome or on that site; Comet cannot run
   Chrome's importer.
2. **macOS Password AutoFill as the fill provider in Comet.** Suggestions
   come from the provider the user enabled in
   System Settings → General → AutoFill & Passwords (for example the
   Passwords app, or a third-party provider that registers as a macOS
   credential provider). Comet never reads that provider's files.
3. **A third-party password-manager extension from the Chrome Web Store**
   remains a user-selectable alternative pathway, because Comet supports
   Chrome extensions. That pathway is the extension's own fill behaviour,
   not Comet's, and no specific manager is claimed to work here without
   being tested on a Mac.

`PasswordAutofillPolicy.googleSyncAvailable` is therefore `false` and the
settings pane reports Google Password Manager as "Not available", in code
and in tests (`CredentialTests.testGooglePasswordManagerIsNotReportedAsConnected`).

## 3. How autofill actually works, end to end

1. **Detection.** `PasswordFieldMonitor` (`Engine/SystemCredentials.swift`)
   polls the selected tab's page and runs `PasswordFieldProbe.script` in
   Chromium's isolated world (via `ECWebContents.evaluateJavaScript`, which
   uses `ExecuteJavaScriptInIsolatedWorld`). The probe reads only field
   types, `autocomplete` attributes, and bounding boxes. It never reads a
   field's value, and its tests assert the script contains no `.value`.
   A `focusin` listener records the last login-field kind so a focused
   field is classified even after the page re-renders (SPA/dynamic forms).
2. **Native suggestion surface.** Chromium draws the page, so macOS cannot
   attach its inline AutoFill glyph to a Chromium input. Instead,
   `PasswordAutoFillHost` places native `NSTextField` /
   `NSSecureTextField` controls, with `.username` / `.password` content
   types, over the login controls at the probed rects. Suggestions shown
   in those controls come from macOS, not from Comet.
3. **User selection.** The user picks a credential in the system UI, or
   uses the menu's Fill Password action / Settings' Test Autofill button,
   which calls `SystemPasswordFill` (`ASAuthorizationPasswordProvider`
   through `ASAuthorizationController`). Multiple matching accounts are
   presented by the system sheet; Comet does not pick one.
4. **Origin recheck and fill.** Before filling, `PasswordFillDecision`
   rechecks that the tab is not private, that the URL is http/https, and
   that the current page is the same origin as the page the request was
   made for. An origin includes a non-default port
   (`CredentialPage.origin`): `https://example.com:8443` is not
   `https://example.com`, and an explicitly default port normalises away.
   A different login domain and authentication domain therefore do not
   share a credential through Comet's matching, even if their names look
   similar.
5. **Field population.** `PasswordFillScript.source` writes the chosen
   username and password into the page's login fields in the isolated
   world and dispatches `input`/`change` events so frameworks notice the
   change. It never submits the form and never calls `requestSubmit`.
   The user completes login normally.

Cases handled:

- Standard username/password forms and email-based usernames.
- **Multi-step sign-in.** A field with `autocomplete="username"` is a
  login field even when no password field exists yet, and the fill script
  fills a username-only step instead of dropping the credential because
  there is no password field. A bare email field with no password field
  is not treated as a login, so newsletter/search forms do not trigger it.
- **Dynamically inserted forms and SPA navigation.** The monitor
  re-probes (currently every 350 ms) and the fill path rechecks the
  current origin; if the page changed, it reports "The page changed, so
  the password was not filled" and writes nothing.
- **Same-origin frames.** The probe and fill scripts search
  same-origin iframes and offset their rects by the frame's position.
  A cross-origin frame is skipped (its `contentDocument` is inaccessible),
  so a credential is never written into a frame Comet cannot verify
  belongs to this page.
- **Cancellation.** Cancelling the system sheet leaves the form
  untouched. A busy request reports "A credential request is already open"
  instead of stacking sheets.

## 4. Import and migration, honestly separated

There are three different stores in this UI, and the settings pane keeps
them distinct:

- **Google Password Manager** — import there via Chrome or
  passwords.google.com, following Google's help. Comet does not open
  another app's database for this and does not copy passwords into a
  Google account.
- **The macOS AutoFill provider** — the only store whose passwords fill
  in Comet. To fill a Google-saved password in Comet, the user exports a
  CSV from Google Password Manager themselves, imports it in the
  Passwords app (File > Import Passwords from File on macOS Sequoia or
  later; menu wording varies by version), enables that provider in
  System Settings → General → AutoFill & Passwords, tests in Comet, and
  deletes the CSV. That is a copy, not a sync: later Google changes do
  not appear in Comet, and macOS-provider saves do not go to Google.
  Imported passwords do not replace existing entries in the Passwords app.
- **This Comet profile's own store** — passwords imported through
  Comet's import window (`ImportFeature.passwordsFile`, Chromium CSV
  parsing in `ec_logins.mm`) go into the profile's Chromium store and are
  reviewable at `chrome://password-manager/passwords`. They are not
  Google Password Manager, are not synced to Google, and are not what
  the macOS suggestion surface shows.

### CSV security disclosure

A password CSV is plain text. Anyone who opens it can read every password
in it. Do not email it, upload it, or leave it in Downloads. Comet never
uploads a credential file to a Comet server, sends credentials to an AI
provider, or logs passwords, and it creates no temporary credential file
as part of this flow. The Passwords app offers to delete the file when
its import finishes; take that offer.

### Import from another browser into a Comet profile

Comet's existing import window can read another Chromium browser's
`Login Data` only with the key the browser keeps in the keychain
(`LoginsReader` / `SafeStorage`); macOS asks the user before that key is
read. That is a user-consented profile import, not a silent extraction,
and it is separate from both Google import and macOS AutoFill.

## 5. Passkeys and WebAuthn

Passkeys are handled independently from password autofill:

- Websites invoke WebAuthn through Chromium, with the engine's
  passkey patches (`engine/patches/0010`, `0011`): a request with no
  dialog to show is cancelled rather than hung, and the sheet is
  presented on the tab's own window.
- When the build carries Apple's web-browser passkey entitlement
  (`com.apple.developer.web-browser.public-key-credential`,
  checked at runtime by `PasskeyEntitlement.isPresent`), macOS presents
  its passkey sheet and private keys stay in the system. The settings
  pane reports the entitlement and the system's authorization state
  (`PasskeyAccess`) truthfully, and can ask macOS to allow passkey
  access; it cannot grant it itself.
- Unsigned/developer builds omit that entitlement, so macOS will not let
  that copy use iCloud passkeys. The pane says so instead of simulating
  a passkey response.
- Passkeys saved only in Google Password Manager inside Chrome are not
  available in Comet, and Comet does not claim Google passkey sync.
- Relying-party ID and origin validation remain Chromium's and the
  platform's; Comet never sees private key material.

## 6. Profile, privacy, and isolation safeguards

- **Private windows** do not offer saved passwords:
  `PasswordFillDecision.canRequest` refuses private tabs, and
  `PasswordAutoFillHost` refuses incognito tabs. Closing a tab cancels
  its pending fill request (`Engine.close`); closing all tabs cancels
  every request.
- **Profile isolation.** Fill requests are bound to a tab and its
  profile's engine context; the origin recheck on apply prevents a
  credential requested for one page from landing on another page after
  navigation. Deleting a profile closes its engine context.
- **No credential leakage to AI or logs.** The page extractor used by
  AI features omits form field values (tested in
  `CredentialTests.testPageExtractOmitsFormFields`), and the password
  monitor and suggestion path are suppressed while the Agent is
  executing or verifying (`AgentActivity` checks in
  `SystemPasswordFill.suggest` and `PasswordFieldMonitor.watch`).
  Credentials are not stored in source, plain-text preferences, or logs;
  the fill script's credential values exist only for the isolated-world
  evaluation that writes them into the page.
- **No automatic submission.** Autofill never submits, and no
  user-enabled auto-submit behaviour is offered, so a filled form is
  still reviewed by the user before it is sent.
- **Provider offline/unavailable.** If macOS returns no credential or
  an error, the user gets a plain message ("macOS did not provide a
  password for this page") and the browser stays responsive; the
  request state is cleared so a later attempt is not blocked.

## 7. Files changed by this work

- `macOS/Comet/Engine/SystemCredentials.swift` — port-aware origin
  matching; multi-step username detection; same-origin iframe probe and
  fill; username-only fill (previously dropped when no password field
  existed).
- `macOS/Comet/Settings/PasswordSettings.swift` — the second migration
  guide: copying Google passwords into the macOS AutoFill provider,
  explicitly labelled as a copy, not a sync.
- `macOS/CometTests/CredentialTests.swift` — port, multi-step,
  iframe, username-only geometry/fill, and macOS-copy tests; all use
  fake credentials only.
- `macOS/Comet/Settings/PASSWORDS_AUTOFILL.md` — this report.

Pre-existing, reused without change: the macOS AutoFill host and system
sheet, the Chromium profile password store and CSV import, the import
window, the passkey entitlement check, and the settings pane itself
(see `git log` for the password-settings commits that landed them).

## 8. Tests and verification status

- **Node harness (this environment, passed).** The probe and fill
  scripts were extracted from `SystemCredentials.swift` and run under
  Node with mocked DOM documents: standard form, username-only step,
  email-only non-login form, same-origin iframe with frame offset, and
  cross-origin frame skipping all returned the expected strings; fill
  returned `filled` for a standard form and for a username-only step,
  and `no-password-field` when no login field existed. The probe
  contains no `.value` or `.submit`.
- **Swift tests (not runnable here).** This Linux environment has no
  Xcode or macOS toolchain, so `xcodebuild test` could not be run and
  is not claimed. The new `CredentialTests` cases are written against
  the existing test harness (JSContext mocks, pure-Swift origin/geometry
  checks) and must be run on a Mac before release; see §9.
- **Not verified at runtime.** No live fill, no system-sheet run, and
  no Passwords-app import were performed here, because none of those
  exist outside macOS. No real user password was used anywhere.

## 9. Manual verification on a Mac

1. Build with Xcode 26.5+ (`sh macOS/scripts/fetch-engine.sh`,
   `xcodegen generate`, run the `Comet` scheme) and run the
   `CredentialTests` target.
2. Open Settings → Passwords and Autofill. Confirm Google Password
   Manager reads "Not available" and the pane explains the Chrome-only
   sync limitation; confirm the macOS provider, storage, and passkey
   sections match the actual build (entitlement present only in a
   signed release).
3. In System Settings → General → AutoFill & Passwords, enable the
   provider that holds a test login you own.
4. Visit that site's login page over https in a normal (non-private)
   Comet window, focus the username field, choose the login from the
   system UI, and confirm the fields fill and the form is not submitted.
5. Repeat for a multi-step login (username first, password on the next
   step) and for a login in a same-origin frame, if the site uses one.
6. Cancel the system sheet and confirm the form is unchanged; navigate
   away mid-request and confirm nothing is filled on the new page.
7. Open a private window and confirm no saved password is offered.
8. For the Google path: import a CSV into Google Password Manager in
   Chrome, confirm it on passwords.google.com, then separately export
   it, import it in the Passwords app, enable that provider, and
   confirm it fills in Comet — then delete the CSV and confirm the
   Google import alone did not make it fill.
9. For passkeys: on a signed release, confirm a WebAuthn login presents
   the macOS sheet, and that cancelling it fails the login cleanly
   without hanging the tab.

## 10. Remaining limitations

- Direct Google Password Manager sync in Comet: **unsupported**, by
  Google's service design, not by a Comet bug. Achieving it would
  require Google to offer a supported credential API or sync service
  to third-party browsers; it cannot be added by Comet alone without
  impersonating Chrome or using private endpoints, which this work
  deliberately does not do.
- A login on a different authentication domain from its login page is
  not matched by Comet's exact-origin check; the system provider's own
  associated-domain behaviour may differ and is outside Comet's control.
- A login inside a cross-origin frame cannot be filled by Comet's
  probe/fill scripts, by design; the system sheet path may still offer
  it if the provider recognises that frame's origin, which Comet does
  not override.
- Password generation (suggesting a new strong password) is not part of
  this work; the macOS provider's own generation UI, where it offers
  one, is the supported route.
- The Chromium profile store's save prompt still has no browser window
  to host it (see engine README), so new logins are not saved into the
  profile store from a page in this build; they are saved by the
  user's macOS provider when it offers to.
