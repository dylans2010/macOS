import AppKit
import ComposableArchitecture
import SwiftUI

struct AIPane: View {
  @Shared(.aiSettings) private var settings
  @State private var apiKey = ""
  @State private var showsKey = false
  @State private var status: String?
  @State private var isSaving = false
  @State private var discovered: [DiscoveredModel] = []
  @State private var fetching = false
  @State private var fetchTask: Task<Void, Never>?
  @State private var headerDraft = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        VStack(spacing: 0) {
          SettingsToggle("Enable AI Features", isOn: $settings.isEnabled)
          Text("When this is off, Comet does not send page content or questions to a provider. Instant Links and on-device Tidy still work.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .settingsCard()

        providerCard
        featuresCard
        agentCard

        HStack {
          Button("Clear Cached Summaries", action: clearCache)
          Button("Reset Feature Preferences", action: reset)
          Spacer()
        }
        .padding(.top, 4)
        if let status {
          Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 20)
      .padding(.horizontal, 64)
    }
    .onAppear { loadKey() }
    .onChange(of: settings.provider) { _, _ in
      loadKey()
      discovered = []
      headerDraft = ""
      fetchTask?.cancel()
    }
    .onChange(of: settings.baseURL) { _, _ in
      discovered = []
    }
    .onDisappear { fetchTask?.cancel() }
  }

  private var providerCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Provider").font(.system(size: 13, weight: .semibold)).padding([.horizontal, .top], 10)
      SettingsRow("Service") {
        Picker("", selection: providerBinding) {
          ForEach(AIProviderKind.allCases.filter(\.isAvailable), id: \.self) { kind in
            Text(kind.title).tag(kind)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 220)
      }
      Text(settings.provider.detail)
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.bottom, 8)
      if let warning = EndpointPolicy.warning(for: settings.baseURL.isEmpty ? (settings.provider.defaultBaseURL?.absoluteString ?? "") : settings.baseURL),
        settings.provider.showsBaseURL || settings.provider == .custom
      {
        Text(warning).font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 10).padding(.bottom, 6)
        SettingsToggle("Allow insecure HTTP for this endpoint", isOn: $settings.allowInsecureHTTP)
      }
      if settings.provider.showsBaseURL {
        SettingsRow("Base URL") {
          TextField(settings.provider.defaultBaseURL?.absoluteString ?? "https://", text: stringBinding(\.baseURL))
            .textFieldStyle(.roundedBorder)
            .frame(width: 280)
        }
      }
      SettingsRow("Model") {
        TextField(settings.provider.defaultModel.isEmpty ? "model-id" : settings.provider.defaultModel, text: stringBinding(\.model))
          .textFieldStyle(.roundedBorder)
          .frame(width: 220)
      }
      modelDiscovery
      if settings.provider != .apple {
        headerEditor
      }
      if settings.provider.needsAPIKey || settings.provider == .custom {
        SettingsRow("API Key") {
          HStack(spacing: 6) {
            Group {
              if showsKey {
                TextField("Key", text: $apiKey)
              } else {
                SecureField(AICredentials.hasKey(settings.provider) ? "Key saved in Keychain" : "Key", text: $apiKey)
              }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            Button(showsKey ? "Hide" : "Show") { showsKey.toggle() }
            Button("Save", action: saveKey).disabled(isSaving)
          }
        }
        Text("The key is stored in the Keychain on this Mac. It is never shown in a page, log, or cached summary.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .padding(.horizontal, 10).padding(.bottom, 10)
      } else if settings.provider == .apple {
        availabilityRow
      }
    }
    .settingsCard()
  }

  @ViewBuilder private var modelDiscovery: some View {
    if settings.provider == .apple {
      Text("Apple Intelligence uses the on-device system model. There is no model list to fetch.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.bottom, 8)
    } else {
      HStack(spacing: 8) {
        if fetching {
          Button("Cancel", action: cancelFetch)
          ProgressView().controlSize(.small)
        } else {
          Button("Fetch Models", action: fetchModels).disabled(!canFetchModels)
        }
        if !discovered.isEmpty {
          Picker("Fetched models", selection: stringBinding(\.model)) {
            if !settings.model.isEmpty && !discovered.contains(where: { $0.id == settings.model }) {
              Text("\(settings.model) (not in the last list)").tag(settings.model)
            }
            Text("Select a model").tag("")
            ForEach(discovered) { model in
              Text(model.pickerTitle).tag(model.id)
            }
          }
          .labelsHidden()
          .frame(width: 260)
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 6)
      if let selected = discovered.first(where: { $0.id == settings.resolvedModel }) {
        Text(capabilityLine(selected))
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .padding(.horizontal, 10).padding(.bottom, 6)
      }
      Text("Fetch Models calls this endpoint’s model list. The choice is the model Comet Intelligence sends.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.bottom, 8)
    }
  }

  private func capabilityLine(_ model: DiscoveredModel) -> String {
    if model.capabilitiesKnown {
      let list = model.capabilities.isEmpty ? "none reported" : model.capabilities.joined(separator: ", ")
      return "Capabilities: \(list)"
    }
    return "Capabilities unknown"
  }

  private var canFetchModels: Bool {
    guard settings.provider != .apple, let base = settings.resolvedBaseURL else { return false }
    guard EndpointPolicy.allows(base, allowInsecureHTTP: settings.allowInsecureHTTP || settings.provider == .ollama) else { return false }
    if settings.provider.allowsEmptyKey { return true }
    if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    return AICredentials.hasKey(settings.provider)
  }

  private var headerEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Custom headers").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10)
      Text("One Name: value per line. Saved in the Keychain for this service. Leave empty and save to remove them. Cookie and Host are ignored.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 10)
      TextEditor(text: $headerDraft)
        .font(.system(size: 12, design: .monospaced))
        .frame(minHeight: 56)
        .padding(4)
        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .accessibilityLabel("Custom headers")
      HStack {
        Button("Save Headers", action: saveHeaders)
        if AIExtraHeaders.load(settings.provider).isEmpty {
          Text("No custom headers saved").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
          Text("Custom headers are saved in the Keychain").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 10)
    }
  }

  @ViewBuilder private var availabilityRow: some View {
    HStack {
      Image(systemName: AIApple.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(AIApple.isAvailable ? .green : .yellow)
      Text(AIApple.isAvailable ? "Apple Intelligence is available on this Mac." : "Apple Intelligence is not available on this Mac.")
        .font(.system(size: 12))
      Spacer()
    }
    .padding(10)
  }

  private var promptBinding: Binding<String> {
    Binding(
      get: { settings.agentSystemPrompt },
      set: { value in $settings.withLock { $0.agentSystemPrompt = value } })
  }

  private var agentCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Agent").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.top, 10)
      Text("The system prompt is sent with every Agent request. Page text is wrapped as untrusted data and cannot change these rules.")
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10)
      TextEditor(text: promptBinding)
        .font(.system(size: 12, design: .monospaced))
        .frame(minHeight: 120)
        .padding(6)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
      HStack {
        Button("Restore Default Prompt") { $settings.withLock { $0.agentSystemPrompt = "" } }
        Spacer()
      }
      .padding(.horizontal, 10)
      SettingsToggle("Ask before Agent clicks, types, or changes a control", isOn: $settings.confirmAgentActions)
      Text("Navigation always asks. Reading the page does not. Agent never submits a form on its own.")
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 10)
    }
    .settingsCard()
  }

  private var featuresCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Capabilities").font(.system(size: 13, weight: .semibold)).padding([.horizontal, .top], 10)
      ForEach(AIFeatureID.allCases, id: \.self) { feature in
        Divider().padding(.horizontal, 10)
        featureRow(feature)
      }
    }
    .settingsCard()
  }

  private func featureRow(_ feature: AIFeatureID) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(feature.title).font(.system(size: 13))
        if !feature.shortcut.isEmpty {
          Text(feature.shortcut).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).frame(height: 18)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        }
        Spacer()
        Toggle("", isOn: binding(feature)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
          .disabled(feature.usesProvider && !settings.isEnabled && feature != .instantLinks)
      }
      Text(feature.summary).font(.system(size: 11)).foregroundStyle(.secondary)
      Text(feature.privacy).font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.9))
      if feature.usesProvider && !settings.isEnabled {
        Text("Requires Enable AI Features.").font(.system(size: 11)).foregroundStyle(.orange.opacity(0.9))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private var providerBinding: Binding<AIProviderKind> {
    Binding(
      get: { settings.provider },
      set: { value in
        $settings.withLock {
          if $0.provider != value { $0.model = "" }
          $0.provider = value
        }
      })
  }

  private func stringBinding(_ keyPath: WritableKeyPath<AISettings, String>) -> Binding<String> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { value in $settings.withLock { $0[keyPath: keyPath] = value } })
  }

  private func binding(_ feature: AIFeatureID) -> Binding<Bool> {
    Binding(
      get: {
        switch feature {
        case .linkPreviews: settings.linkPreviews
        case .askOnPage: settings.askOnPage
        case .tidyTabs: settings.tidyTabs
        case .tidyTabTitles: settings.tidyTabTitles
        case .tidyDownloads: settings.tidyDownloads
        case .commandBarAsk: settings.commandBarAsk
        case .instantLinks: settings.instantLinks
        case .agent: settings.agent
        }
      },
      set: { value in $settings.withLock { $0.set(feature, enabled: value) } }
    )
  }

  private func loadKey() {
    apiKey = ""
    showsKey = false
  }

  private func fetchModels() {
    guard !fetching else { return }
    let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = typed.isEmpty ? AICredentials.load(settings.provider) : typed
    let snapshot = settings
    fetching = true
    status = "Fetching models…"
    fetchTask?.cancel()
    fetchTask = Task {
      defer { fetching = false }
      do {
        let models = try await ModelDiscovery.fetch(settings: snapshot, key: key)
        if Task.isCancelled { return }
        discovered = models
        if !snapshot.model.isEmpty && !models.contains(where: { $0.id == snapshot.model }) {
          status = "Fetched \(models.count) models. The selected model was not in the list."
        } else {
          status = "Fetched \(models.count) models."
        }
      } catch is CancellationError {
        status = "Model discovery was cancelled."
      } catch let error as AIFailure {
        status = error.message
      } catch {
        status = "Model discovery failed."
      }
    }
  }

  private func cancelFetch() {
    fetchTask?.cancel()
    fetching = false
    status = "Model discovery was cancelled."
  }

  private func saveHeaders() {
    let headers = AIExtraHeaders.parse(headerDraft)
    let statusCode = AIExtraHeaders.save(settings.provider, headers: headers)
    if statusCode == errSecSuccess {
      headerDraft = ""
      status = headers.isEmpty ? "Custom headers removed." : "Custom headers saved in the Keychain."
    } else {
      status = "Custom headers could not be saved."
    }
  }

  private func saveKey() {
    isSaving = true
    let status = AICredentials.save(settings.provider, key: apiKey)
    isSaving = false
    self.status = status == errSecSuccess ? "API key saved in the Keychain." : "The API key could not be saved."
    if status == errSecSuccess { apiKey = "" }
  }

  private func clearCache() {
    Task { await AIRuntime.shared.clearCache() }
    status = "Cached summaries were cleared."
  }

  private func reset() {
    let provider = settings.provider
    let model = settings.model
    let baseURL = settings.baseURL
    $settings.withLock {
      $0 = AISettings(isEnabled: $0.isEnabled, provider: provider, model: model, baseURL: baseURL)
    }
    status = "Feature preferences were reset. Provider settings were kept."
  }
}
