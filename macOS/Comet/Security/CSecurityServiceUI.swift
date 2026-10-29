import AppKit
import SwiftUI
import UniformTypeIdentifiers

// CSecurityServiceUI: the native password-management settings interface
// for Security. It replaces the old PasswordsPane as the Passwords and
// Autofill pane (see SettingsWindow). The old pane's macOS-provider,
// Google, and passkey disclosures are kept below as an "Other providers"
// section, because they describe external stores accurately; they are
// not Security, and the UI never presents them as Security.
//
// Rules this UI follows:
// - The list shows metadata only. A password is fetched (and only after
//   authentication) when the user opens a credential and taps Reveal,
//   or when autofill releases it. The list never loads every plaintext
//   password to render itself.
// - No mock entries, no demo credentials, no fake connection states.
//   An empty vault shows an empty state, not invented logins.
// - Deletion asks for confirmation and reports success only after the
//   vault write succeeds.
// - The CSV source file is never deleted by Comet and never uploaded.
//   The import summary reminds the user to delete it themselves.
struct CSecurityServiceUI: View {
  @State private var service = CSecurityService.shared
  @State private var credentials: [CSecurityCredential.Metadata] = []
  @State private var search = ""
  @State private var status: String?
  @State private var editor: EditorDraft?
  @State private var deleting: CSecurityCredential.Metadata?
  @State private var importPreview: ImportPreview?
  @State private var showOtherProviders = false
  @State private var passkeys = PasskeyAccess.current()
  @State private var passkeyStatus: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("Security").font(.system(size: 13, weight: .semibold))
        Text("Your passwords are encrypted on this Mac with a key kept in the Keychain. They are not synced, uploaded, or sent to any service. If the Keychain item is deleted, the vault cannot be recovered — there is no master password to reset it with.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if !service.isVaultReady {
          vaultLockedSection
        } else {
          vaultControls
          searchField
          credentialList
        }
        if let status {
          Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Button(showOtherProviders ? "Hide Other Providers" : "Other Providers: macOS AutoFill, Google, Passkeys") {
          showOtherProviders.toggle()
        }
        if showOtherProviders { otherProviders }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear(perform: refresh)
    .sheet(item: $editor) { draft in
      CredentialEditor(draft: draft, onSave: { saved in
        editor = nil
        status = saved ? "Saved to Security." : "Could not save to Security."
        refresh()
      }, onCancel: { editor = nil })
    }
    .sheet(item: $importPreview) { preview in
      CSVImportView(preview: preview, onDone: { summary in
        importPreview = nil
        status = summary
        refresh()
      }, onCancel: { importPreview = nil })
    }
    .alert("Delete this login?", isPresented: Binding(
      get: { deleting != nil },
      set: { if !$0 { deleting = nil } }
    )) {
      Button("Delete", role: .destructive) { deleteConfirmed() }
      Button("Cancel", role: .cancel) { deleting = nil }
    } message: {
      if let deleting {
        Text("Delete \(deleting.username) for \(deleting.origin)? This cannot be undone.")
      }
    }
  }

  // MARK: - Vault state

  private var vaultLockedSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(service.vaultError == .vaultCorrupted
        ? "The Security vault could not be read. It has not been overwritten; the previous good copy was tried and also failed. Do not delete the vault file until you have a backup of it."
        : "Security is locked.")
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Unlock Security") {
        service.unlock()
        refresh()
        status = service.isVaultReady ? "Security unlocked." : "Security could not be unlocked."
      }
    }
  }

  private var vaultControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button("Add Login") { editor = EditorDraft() }
        Button("Import CSV…", action: chooseCSV)
        Button("Lock Security") {
          service.lock()
          credentials = []
          status = "Security locked. Passwords are purged from memory until you unlock again."
        }
        Spacer()
        Text(service.isAuthenticated ? "Authenticated" : "Passwords need \(service.authPolicy.promise)")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      HStack {
        Picker("Require", selection: Binding(
          get: { service.authPolicy },
          set: { service.authPolicy = $0; status = "Authentication preference saved." }
        )) {
          Text("Touch ID or password").tag(CSecurityService.AuthPolicy.system)
          Text("Touch ID only").tag(CSecurityService.AuthPolicy.biometricsOnly)
        }
        .pickerStyle(.segmented)
        .frame(width: 280)
        Picker("Generated length", selection: Binding(
          get: { service.generationSettings.length },
          set: {
            service.generationSettings = CSecurityPasswordGenerator.Settings(length: $0)
            status = "Generated passwords will be \($0) characters."
          }
        )) {
          ForEach(8...12, id: \.self) { length in Text("\(length)").tag(length) }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
      }
      Text("Authentication is checked again before any password is shown or filled, and a session lasts \(Int(service.lockTimeout / 60)) minutes. The list itself shows only website names and usernames.")
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var searchField: some View {
    TextField("Search by website or username", text: $search)
      .textFieldStyle(.roundedBorder)
  }

  private var filtered: [CSecurityCredential.Metadata] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return credentials }
    return credentials.filter {
      $0.origin.lowercased().contains(query) || $0.username.lowercased().contains(query)
        || ($0.displayName?.lowercased().contains(query) == true)
    }
  }

  private var credentialList: some View {
    VStack(alignment: .leading, spacing: 8) {
      if filtered.isEmpty {
        Text(credentials.isEmpty
          ? "No logins saved in Security yet. Add one, import a CSV, or save a login from a website and confirm the prompt."
          : "No logins match that search.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(filtered) { credential in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(credential.title).font(.system(size: 13, weight: .medium))
            Text(credential.username).font(.system(size: 12)).foregroundStyle(.secondary)
            if let lastUsed = credential.lastUsed {
              Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
              Text("Modified \(credential.modified.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button("Edit") { editor = EditorDraft(existing: credential) }
          Button("Delete", role: .destructive) { deleting = credential }
        }
        .padding(.vertical, 2)
        Divider()
      }
    }
  }

  // MARK: - Actions

  private func refresh() {
    if !service.isVaultReady { service.prepare() }
    credentials = (try? service.metadata()) ?? []
    if service.vaultError != nil, service.isVaultReady == false {
      status = "Security could not be opened. Your vault file was not overwritten."
    }
  }

  private func deleteConfirmed() {
    guard let deleting else { return }
    do {
      try service.delete(id: deleting.id)
      status = "Deleted."
    } catch {
      status = "Could not delete that login."
    }
    self.deleting = nil
    refresh()
  }

  private func chooseCSV() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.message = "Choose the CSV you exported from another password manager."
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let file = panel.url else { return }
    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
      status = "Could not read that CSV file."
      return
    }
    guard let rows = CSecurityCSV.parse(text), !rows.isEmpty else {
      status = "That CSV could not be parsed. Check it is a CSV export and try again."
      return
    }
    importPreview = ImportPreview(file: file, rows: rows)
  }

  // MARK: - Other providers (disclosure, not Security)

  private var otherProviders: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("macOS Password AutoFill").font(.system(size: 13, weight: .semibold))
      Text(PasswordAutofillPolicy.storage)
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Fill on This Page from Security", action: fillOnThisPage)
        Button("Test macOS Autofill on This Page", action: testMacOSFill)
      }
      Text("Fill on This Page asks Security for this page's logins, shows the account before filling, and never submits the form. Test macOS Autofill asks the system provider instead; those are different stores.")
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Text("Google Password Manager: \(PasswordAutofillPolicy.googleStatus)").font(.system(size: 13, weight: .semibold))
      Text(PasswordAutofillPolicy.googleLimitation)
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Open Google Password Manager") { NSWorkspace.shared.open(PasswordAutofillPolicy.googleManager) }
        Button("Google's Import Help") { NSWorkspace.shared.open(PasswordAutofillPolicy.googleImportHelp) }
      }
      Text("Passkeys").font(.system(size: 13, weight: .semibold))
      Text(PasskeyEntitlement.isPresent ? PasswordAutofillPolicy.passkeyNote : "Developer and unsigned builds omit Apple's web-browser passkey entitlement, so macOS will not let this copy use iCloud passkeys. A signed release presents the system sheet. Comet does not invent passkey responses. " + PasswordAutofillPolicy.passkeyNote)
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      LabeledContent("This build", value: PasskeyEntitlement.isPresent ? "Signed for passkeys" : "Not signed for passkeys").font(.system(size: 12))
      LabeledContent("macOS access", value: passkeys.title).font(.system(size: 12))
      Button("Ask macOS to Allow Passkeys") {
        Task {
          passkeys = await PasskeyAccess.request()
          passkeyStatus = passkeys == .authorized ? "macOS allowed passkey access." : "macOS did not allow passkey access (\(passkeys.title))."
        }
      }
      if let passkeyStatus {
        Text(passkeyStatus).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Text("This profile's Chromium store").font(.system(size: 13, weight: .semibold))
      Text(PasswordAutofillPolicy.profileStore)
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button("Review Passwords Saved in This Profile") { NSWorkspace.shared.open(PasswordAutofillPolicy.profilePasswords) }
    }
    .padding(12)
    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
  }

  private func fillOnThisPage() {
    guard let tab = FrontBrowser.tabID, let url = FrontBrowser.url else {
      status = PasswordAutofillPolicy.noPage
      return
    }
    Task {
      switch await CSecurityAutofillFlow.fill(tab: tab, url: url) {
      case .filled(let username): status = "Filled the login for \(username). The form was not submitted."
      case .noSecurityMatches: status = "Security has no login for this site. Use Test macOS Autofill for the system provider, or add the login here."
      case .cancelled: status = "Canceled."
      case .failed(let message): status = message
      }
    }
  }

  private func testMacOSFill() {
    guard let tab = FrontBrowser.tabID, let url = FrontBrowser.url else {
      status = PasswordAutofillPolicy.noPage
      return
    }
    SystemPasswordFill.shared.start(tab: tab, url: url) { message in
      status = message.isEmpty ? PasswordAutofillPolicy.noPage : message
    }
  }
}

// MARK: - Add / edit editor

private struct EditorDraft: Identifiable {
  var id: UUID
  var existingID: UUID?
  var url = ""
  var username = ""
  var password = ""
  var displayName = ""
  var showPassword = false
  var revealedPassword: String?

  init() {
    id = UUID()
  }

  init(existing: CSecurityCredential.Metadata) {
    id = UUID()
    existingID = existing.id
    url = existing.url
    username = existing.username
    displayName = existing.displayName ?? ""
  }
}

private struct CredentialEditor: View {
  @State var draft: EditorDraft
  var onSave: (Bool) -> Void
  var onCancel: () -> Void

  @State private var error: String?
  @State private var generatedSaved = false
  @State private var savedGeneratedID: UUID?
  @State private var generatedChoice: (existing: CSecurityCredential.Metadata, generated: CSecurityCredential)?

  private var service: CSecurityService { CSecurityService.shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(draft.existingID == nil ? "Add Login to Security" : "Edit Login in Security")
        .font(.system(size: 14, weight: .semibold))
      TextField("Website URL", text: $draft.url)
      TextField("Username", text: $draft.username)
      HStack {
        if draft.showPassword {
          TextField("Password", text: $draft.password)
        } else {
          SecureField("Password", text: $draft.password)
        }
        Button(draft.showPassword ? "Hide" : "Show") { draft.showPassword.toggle() }
        Button("Generate Password", action: generate)
      }
      TextField("Display name (optional)", text: $draft.displayName)
      if generatedSaved {
        Text("Generated password saved to Security automatically. You can still edit it here and save again.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if let error {
        Text(error).font(.system(size: 12)).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Button("Save", action: save).keyboardShortcut(.defaultAction)
          .disabled(draft.url.isEmpty || draft.username.isEmpty || draft.password.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 460)
    .textFieldStyle(.roundedBorder)
    .alert("A login already exists for this site", isPresented: Binding(
      get: { generatedChoice != nil },
      set: { if !$0 { generatedChoice = nil } }
    )) {
      Button("Replace It") { resolveChoice(.replace) }
      Button("Keep Both as Separate Accounts") { resolveChoice(.keepBoth) }
      Button("Cancel", role: .cancel) { generatedChoice = nil }
    } message: {
      Text("Replace the existing login, or keep the generated password as a second account for the same site? Nothing has been overwritten yet.")
    }
  }

  private func generate() {
    guard let generated = try? CSecurityPasswordGenerator.generate(settings: service.generationSettings) else {
      error = "Could not generate a password. The system's secure random source failed."
      return
    }
    guard let credential = CSecurityCredential.make(
      url: draft.url, username: draft.username, password: generated)
    else {
      error = "Enter a valid website URL and username before generating a password."
      return
    }
    draft.password = credential.password
    draft.showPassword = true
    do {
      switch try service.saveGenerated(credential) {
      case .saved(let saved):
        savedGeneratedID = saved.id
        generatedSaved = true
        error = nil
      case .needsChoice(let existing, let generated):
        generatedChoice = (existing, generated)
      }
    } catch {
      error = "The generated password could not be saved to Security. It is shown above so you can copy it, but it is not saved yet."
    }
  }

  private func resolveChoice(_ choice: CSecurityService.GeneratedChoice) {
    guard let pending = generatedChoice else { return }
    do {
      try service.resolveGeneratedChoice(choice, existing: pending.existing, generated: pending.generated)
      savedGeneratedID = pending.generated.id
      generatedSaved = true
      generatedChoice = nil
      error = nil
    } catch {
      generatedChoice = nil
      error = "Could not save the generated password."
    }
  }

  private func save() {
    guard var credential = CSecurityCredential.make(
      url: draft.url, username: draft.username, password: draft.password,
      displayName: draft.displayName.isEmpty ? nil : draft.displayName)
    else {
      error = "Enter a valid website URL, username, and password."
      return
    }
    if let savedGeneratedID { credential.id = savedGeneratedID }
    else if let existingID = draft.existingID { credential.id = existingID }
    do {
      try service.save(credential)
      onSave(true)
    } catch {
      onSave(false)
    }
  }
}

// MARK: - CSV import preview

private struct ImportPreview: Identifiable {
  var id = UUID()
  var file: URL
  var rows: [CSecurityCSV.Row]
}

private struct CSVImportView: View {
  var preview: ImportPreview
  var onDone: (String) -> Void
  var onCancel: () -> Void

  @State private var mapping: CSecurityCSV.Mapping
  @State private var headers: [String]

  init(preview: ImportPreview, onDone: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
    self.preview = preview
    self.onDone = onDone
    self.onCancel = onCancel
    let detected = CSecurityCSV.detectMapping(headerRow: preview.rows.first)
    _mapping = State(initialValue: detected.hasHeaderRow ? detected : CSecurityCSV.positionalMapping)
    if detected.hasHeaderRow {
      _headers = State(initialValue: preview.rows.first?.columns ?? [])
    } else {
      _headers = State(initialValue: preview.rows.first?.columns.indices.map { "Column \($0 + 1)" } ?? [])
    }
  }

  private var dataRows: [CSecurityCSV.Row] {
    mapping.hasHeaderRow ? Array(preview.rows.dropFirst()) : preview.rows
  }

  private var outcomes: [CSecurityCSV.RowOutcome] {
    let existing = (try? CSecurityService.shared.metadata()) ?? []
    return CSecurityCSV.deduplicateWithinFile(
      CSecurityCSV.validate(rows: dataRows, mapping: mapping, existing: existing))
  }

  private var importable: [CSecurityCredential] {
    outcomes.compactMap { if case let .credential(credential) = $0 { credential } else { nil } }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Import CSV into Security").font(.system(size: 14, weight: .semibold))
      Text("A password CSV is readable text. Comet never uploads this file or deletes it for you — delete it yourself after importing. Review the fields and counts below before committing anything.")
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      Text("File: \(preview.file.lastPathComponent) — \(dataRows.count) rows detected.")
        .font(.system(size: 12)).foregroundStyle(.secondary)
      ForEach(CSecurityCSV.Field.allCases, id: \.rawValue) { field in
        Picker("\(field.rawValue.capitalized) column", selection: Binding(
          get: { mapping.columns[field] ?? -1 },
          set: { mapping.columns[field] = $0 < 0 ? nil : $0 }
        )) {
          Text("None").tag(-1)
          ForEach(headers.indices, id: \.self) { index in
            Text(headers[index]).tag(index)
          }
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
            switch outcome {
            case .credential(let credential):
              Text("Import: \(credential.origin) (\(credential.username))").font(.system(size: 12))
            case .duplicate(let metadata):
              Text("Skip (already saved): \(metadata.origin) (\(metadata.username))").font(.system(size: 12)).foregroundStyle(.secondary)
            case .skipped(let reason):
              Text("Skip: \(reason)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
          }
        }
      }
      .frame(maxHeight: 220)
      HStack {
        Spacer()
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Button("Import \(importable.count)", action: commit)
          .keyboardShortcut(.defaultAction)
          .disabled(importable.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 520)
  }

  private func commit() {
    do {
      let summary = try CSecurityService.shared.importCredentials(importable)
      let skipped = outcomes.count - importable.count
      onDone("Imported \(summary.imported) logins into Security. \(summary.duplicates + skipped) rows skipped. Delete the CSV file yourself — Comet did not delete it.")
    } catch {
      onDone("Import failed. Nothing was committed to Security.")
    }
  }
}
