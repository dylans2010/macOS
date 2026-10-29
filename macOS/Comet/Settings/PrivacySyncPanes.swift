import AppKit
import ComposableArchitecture
import SwiftUI

enum PrivacyPreset: String, CaseIterable, Identifiable, Sendable {
  case balanced, strict, custom, off
  var id: String { rawValue }
  var title: String {
    switch self {
    case .balanced: "Balanced"
    case .strict: "Strict"
    case .custom: "Custom"
    case .off: "Off"
    }
  }

  var detail: String {
    switch self {
    case .balanced: "Loads uBlock Origin. Its lists block many ads and known trackers together."
    case .strict: "Same network filter as Balanced. Comet has no separate stricter engine to turn on."
    case .custom: "Leaves the uBlock switch as you set it."
    case .off: "Unloads uBlock Origin. Pages load their ads and trackers."
    }
  }

  var enablesBlocker: Bool? {
    switch self {
    case .balanced, .strict: true
    case .off: false
    case .custom: nil
    }
  }
}

extension SharedKey where Self == AppStorageKey<String>.Default {
  static var privacyPreset: Self { Self[.appStorage("privacyPreset"), default: PrivacyPreset.balanced.rawValue] }
}

extension SharedKey where Self == AppStorageKey<Double>.Default {
  static var adBlockPausedUntil: Self { Self[.appStorage("adBlockPausedUntil"), default: 0] }
}

struct PrivacyPane: View {
  let openPage: (URL) -> Void
  @Shared(.blocksAds) private var blocksAds
  @Shared(.privacyPreset) private var presetRaw
  @Shared(.adBlockPausedUntil) private var pausedUntil

  private var preset: PrivacyPreset { PrivacyPreset(rawValue: presetRaw) ?? .balanced }
  private var paused: Bool { pausedUntil > Date().timeIntervalSince1970 }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("uBlock Origin is the only request filter Comet loads. It covers ads and many trackers in one extension. Turning it off stops both. Comet does not invent blocked-request counts.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Picker("Preset", selection: Binding(get: { preset }, set: apply)) {
          ForEach(PrivacyPreset.allCases) { item in Text(item.title).tag(item) }
        }
        .pickerStyle(.segmented)
        Text(preset.detail).font(.system(size: 12)).foregroundStyle(.secondary)
        SettingsToggle("Block ads and trackers with uBlock Origin", isOn: $blocksAds)
          .onChange(of: blocksAds) { _, _ in
            $presetRaw.withLock { $0 = PrivacyPreset.custom.rawValue }
            Engine.shared.adBlockingDidChange()
          }
        HStack {
          Button(paused ? "Resume blocking" : "Pause for 10 minutes", action: togglePause)
          Button("Open filter dashboard") { openPage(URL(string: "chrome://extensions")!) }
          Button("Clear browsing data…") { openPage(URL(string: "chrome://settings/clearBrowserData")!) }
        }
        GroupBox("What is not a separate switch") {
          VStack(alignment: .leading, spacing: 6) {
            Text("Tracker blocking is not a second list. It is part of uBlock.")
            Text("Fingerprinting resistance is not implemented here. Comet does not spoof canvas, audio, or screen values, and it does not claim anonymity.")
            Text("Per-site camera, microphone, location, and notification choices stay on the page’s site controls. They are Chromium’s permissions.")
            Text("Cookie exceptions are Chromium’s site data. Use Clear browsing data for a time range, or the site controls for one permission.")
          }
          .font(.system(size: 12))
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(24)
    }
    .onAppear(perform: resumeIfExpired)
  }

  private func apply(_ next: PrivacyPreset) {
    $presetRaw.withLock { $0 = next.rawValue }
    if let enabled = next.enablesBlocker {
      $blocksAds.withLock { $0 = enabled }
      Engine.shared.adBlockingDidChange()
    }
  }

  private func togglePause() {
    if paused {
      $pausedUntil.withLock { $0 = 0 }
      $blocksAds.withLock { $0 = true }
    } else {
      $pausedUntil.withLock { $0 = Date().addingTimeInterval(600).timeIntervalSince1970 }
      $blocksAds.withLock { $0 = false }
    }
    Engine.shared.adBlockingDidChange()
  }

  private func resumeIfExpired() {
    guard pausedUntil > 0, pausedUntil <= Date().timeIntervalSince1970 else { return }
    $pausedUntil.withLock { $0 = 0 }
    $blocksAds.withLock { $0 = true }
    Engine.shared.adBlockingDidChange()
  }
}

struct SyncPane: View {
  @State private var folder: URL?
  @State private var status = "Local only"
  @State private var conflicts: [SyncConflict] = []
  @State private var passphrase = ""
  @State private var webDAV = ""
  @State private var webUser = ""
  @State private var webPassword = ""
  @Shared(.notes) private var notes
  @Shared(.easels) private var easels

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(status).font(.system(size: 13, weight: .semibold))
        Text("Sync writes a file you choose. Comet does not run a database. A shared folder is safe when one Mac writes at a time. If two copies edit the same note, both are kept until you choose.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        HStack {
          Button("Choose Folder…", action: chooseFolder)
          Button("Sync Now", action: syncFolder).disabled(folder == nil)
          Button("Export Encrypted…", action: exportSealed)
          Button("Import Encrypted…", action: importSealed)
        }
        SecureField("Passphrase for encrypted transfer", text: $passphrase).textFieldStyle(.roundedBorder)
        Text("The passphrase never leaves this Mac with the file. Losing it means the sealed file cannot be opened. A folder sync without a passphrase is not end-to-end encrypted.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        Divider()
        Text("WebDAV").font(.system(size: 13, weight: .semibold))
        TextField("https://server/remote/CometSync.json", text: $webDAV).textFieldStyle(.roundedBorder)
        TextField("Username", text: $webUser).textFieldStyle(.roundedBorder)
        SecureField("Password", text: $webPassword).textFieldStyle(.roundedBorder)
        Button("Test and sync WebDAV", action: syncWebDAV)
        if !conflicts.isEmpty {
          Text("\(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold))
          ForEach(conflicts) { conflict in
            HStack {
              Text(conflict.local.type).font(.system(size: 12))
              Button("Keep this Mac") { resolve(conflict, keepRemote: false) }
              Button("Keep other copy") { resolve(conflict, keepRemote: true) }
            }
          }
        }
      }
      .padding(24)
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    guard panel.runModal() == .OK else { return }
    folder = panel.url
    status = "Folder selected. Not synced yet."
  }

  private func syncFolder() {
    guard let folder else { return }
    do {
      let remote = try FolderSync.read(from: folder)
      let outcome = publish(merging: remote)
      try FolderSync.write(outcome.records, to: folder)
      conflicts = outcome.conflicts
      status = outcome.conflicts.isEmpty ? "Up to date" : "Conflicts need attention"
    } catch {
      status = "Sync failed: \(error.localizedDescription)"
    }
  }

  private func publish(merging remote: [SyncRecord]) -> SyncMergeResult {
    @Shared(.syncState) var state
    var current = state
    let local = SyncSnapshot.records(notes: Array(notes), easels: Array(easels), state: &current)
    $state.withLock { $0 = current }
    return SyncMerge.merge(local: local, remote: remote)
  }

  private func resolve(_ conflict: SyncConflict, keepRemote: Bool) {
    let chosen = keepRemote ? conflict.remote : conflict.local
    apply([chosen])
    conflicts.removeAll { $0.entity == conflict.entity }
    status = conflicts.isEmpty ? "Conflict resolved" : "Conflicts need attention"
  }

  private func apply(_ records: [SyncRecord]) {
    for record in records where !record.deleted {
      if record.type == "note", let note = try? JSONDecoder().decode(Note.self, from: record.payload) {
        @Shared(.notes) var notes
        $notes.withLock { if $0[id: note.id] == nil { $0.append(note) } else { $0[id: note.id] = note } }
      }
      if record.type == "easel", let easel = try? JSONDecoder().decode(Easel.self, from: record.payload) {
        @Shared(.easels) var easels
        $easels.withLock { if $0[id: easel.id] == nil { $0.append(easel) } else { $0[id: easel.id] = easel } }
      }
    }
  }

  private func exportSealed() {
    guard !passphrase.isEmpty else { status = "Enter a passphrase before sealing a file."; return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Comet Sync.sealed"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let outcome = publish(merging: [])
      let data = try JSONEncoder().encode(outcome.records)
      try SyncCrypto.seal(data, passphrase: passphrase).write(to: url, options: .atomic)
      status = "Encrypted export written. The passphrase is not in the file."
    } catch {
      status = "Export failed: \(error.localizedDescription)"
    }
  }

  private func importSealed() {
    guard !passphrase.isEmpty else { status = "Enter the passphrase for this file."; return }
    let panel = NSOpenPanel()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let opened = try SyncCrypto.open(Data(contentsOf: url), passphrase: passphrase)
      let remote = try JSONDecoder().decode([SyncRecord].self, from: opened)
      let outcome = publish(merging: remote)
      apply(outcome.records)
      conflicts = outcome.conflicts
      status = outcome.conflicts.isEmpty ? "Imported" : "Imported with conflicts"
    } catch {
      status = "Import failed. The passphrase may be wrong, or the file is not a Comet sync archive."
    }
  }

  private func syncWebDAV() {
    guard let url = URL(string: webDAV), WebDAVSync.allows(url) else {
      status = "WebDAV needs https, or http on this Mac."
      return
    }
    let user = webUser
    let password = webPassword
    Task {
      do {
        var request = WebDAVSync.request(url, method: "GET", user: user, password: password, body: nil)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let remote: [SyncRecord]
        if http?.statusCode == 404 || data.isEmpty {
          remote = []
        } else if let code = http?.statusCode, !(200..<300).contains(code) {
          status = "WebDAV returned \(code)."
          return
        } else {
          remote = (try? JSONDecoder().decode([SyncRecord].self, from: data)) ?? []
        }
        let outcome = publish(merging: remote)
        let body = try JSONEncoder().encode(outcome.records)
        request = WebDAVSync.request(url, method: "PUT", user: user, password: password, body: body)
        let (_, putResponse) = try await URLSession.shared.data(for: request)
        let put = putResponse as? HTTPURLResponse
        guard let code = put?.statusCode, (200..<300).contains(code) else {
          status = "WebDAV upload was not accepted."
          return
        }
        conflicts = outcome.conflicts
        status = outcome.conflicts.isEmpty ? "Up to date" : "Conflicts need attention"
      } catch {
        status = "WebDAV failed: \(error.localizedDescription)"
      }
    }
  }
}

extension SharedKey where Self == FileStorageKey<SyncState>.Default {
  static var syncState: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "SyncState.json")), default: SyncState()]
  }
}
