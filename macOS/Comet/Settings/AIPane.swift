import AppKit
import ComposableArchitecture
import SwiftUI

struct AIPane: View {
  @Shared(.aiSettings) private var settings
  @State private var apiKey = ""
  @State private var showsKey = false
  @State private var status: String?
  @State private var isSaving = false

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
    .onChange(of: settings.provider) { _, _ in loadKey() }
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
      set: { value in $settings.withLock { $0.provider = value } })
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
