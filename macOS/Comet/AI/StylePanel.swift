import AppKit
import ComposableArchitecture
import SwiftUI

private enum StyleInspectorSection: Equatable {
  case none, theme, adjust, size, letters
}

enum StyleChrome {
  static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? light : dark })
  }

  static let background = dynamic(
    NSColor(srgbRed: 0.973, green: 0.973, blue: 0.977, alpha: 0.98),
    NSColor(srgbRed: 0.16, green: 0.165, blue: 0.18, alpha: 0.98))
  static let button = dynamic(NSColor(white: 1, alpha: 1), NSColor(white: 1, alpha: 0.08))
  static let line = dynamic(NSColor(white: 0, alpha: 0.1), NSColor(white: 1, alpha: 0.14))
  static let ink = dynamic(NSColor(srgbRed: 0.14, green: 0.15, blue: 0.17, alpha: 1), NSColor(white: 0.94, alpha: 1))
  static let radius: CGFloat = 22
}

struct StyleSitePanel: View {
  @Bindable private var session = StyleSiteSession.shared
  @Shared(.siteStyles) private var styles
  @State private var diagnostics = StyleDiagnostics.shared
  @State private var section = StyleInspectorSection.none
  @State private var renaming = false
  @State private var nameDraft = ""
  @State private var showScope = false
  @State private var confirmReset = false
  @State private var confirmDelete = false
  @State private var confirmDiscard = false
  @State private var discardClosesPanel = false
  @State private var pendingStyle: SiteStyle.ID?
  @State private var hex = ""
  @FocusState private var hexFocused: Bool
  @State private var dragOrigin: CGSize?
  @State private var escapeMonitor: Any?
  @FocusState private var spectrumFocused: Bool

  private var style: SiteStyle? { session.styleID.flatMap { id in styles.first { $0.id == id } } }
  private var siteStyles: [SiteStyle] { session.styles(for: session.url, in: styles) }
  private var onThisSite: Bool {
    guard let style, let live = session.liveURL ?? session.url else { return true }
    return StyleMatch.matches(live, style, requiringEnabled: false)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .gesture(drag)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let style {
            notices(style)
            spectrum(style)
            hexRow(style)
            mainButtons(style)
            if section == .theme { themeSection(style) }
            if section == .adjust { adjustSection(style) }
            fontGrid(style)
            sizeAndCase(style)
            if section == .size { sizeSection(style) }
            if section == .letters { caseSection(style) }
            zapControl(style)
            if case let .confirming(confirmation) = session.zap { confirmZap(style, confirmation) }
            hiddenList(style)
            codeButton(style)
            if let message = diagnostics.message {
              Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
          } else {
            Text("No style for this site yet.")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
            Button("New Style") { createStyle() }
          }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .background {
          GeometryReader { proxy in
            Color.clear.preference(key: StylePanelHeightKey.self, value: proxy.size.height)
          }
        }
      }
    }
    .foregroundStyle(StyleChrome.ink)
    .background(StyleChrome.background, in: RoundedRectangle(cornerRadius: StyleChrome.radius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: StyleChrome.radius, style: .continuous).strokeBorder(StyleChrome.line))
    .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
    .onPreferenceChange(StylePanelHeightKey.self) { height in
      guard height > 1, abs(session.contentHeight - height) > 2 else { return }
      session.contentHeight = height
    }
    .onAppear {
      hex = style?.color?.rgb.hex ?? ""
      escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.keyCode == 53, StyleSiteSession.shared.zap != .idle else { return event }
        MainActor.assumeIsolated { StyleZap.cancel() }
        return nil
      }
    }
    .onDisappear {
      if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
      self.escapeMonitor = nil
    }
    .onChange(of: style?.id) { _, _ in
      hex = style?.color?.rgb.hex ?? ""
      section = .none
    }
    .confirmationDialog("Reset visual controls?", isPresented: $confirmReset, titleVisibility: .visible) {
      Button("Reset") { guard let style else { return }; StyleEditing.update(style.id) { $0.resetVisuals() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Color, theme, adjustments, font, size, and case return to the website. Hidden elements and custom code stay.")
    }
    .confirmationDialog("Delete this style?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { deleteCurrent() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The saved style is removed from this site. This does not change the website itself.")
    }
    .confirmationDialog("Discard unsaved code?", isPresented: $confirmDiscard, titleVisibility: .visible) {
      Button("Discard", role: .destructive) { discardCode() }
      Button("Cancel", role: .cancel) {
        pendingStyle = nil
        discardClosesPanel = false
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Styles for this site")
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 6)
      .onChanged { value in
        if dragOrigin == nil { dragOrigin = session.offset }
        session.offset = CGSize(
          width: (dragOrigin?.width ?? 0) + value.translation.width,
          height: (dragOrigin?.height ?? 0) + value.translation.height)
        session.styleMoved = true
      }
      .onEnded { _ in dragOrigin = nil }
  }

  private var header: some View {
    HStack(spacing: 8) {
      circleButton("xmark", "Close Styles") { closePanel() }
      Spacer(minLength: 0)
      if renaming, let style {
        TextField("Style name", text: $nameDraft)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 13, weight: .semibold))
          .onSubmit { commitName(style.id) }
          .accessibilityLabel("Style name")
      } else {
        Menu {
          ForEach(siteStyles) { item in
            Button {
              select(item.id)
            } label: {
              if item.id == style?.id { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
            }
          }
          Divider()
          Button("New Style", action: createStyle)
          Button("Rename") {
            nameDraft = style?.name ?? ""
            renaming = true
          }
          Button(style?.enabled == true ? "Turn Off" : "Turn On") { toggleEnabled() }
          Button(showScope ? "Hide Site Scope" : "Site Scope") { showScope.toggle() }
          Divider()
          Button("All Styles") { StyleSiteSession.openManager() }
          Button("Delete Style…", role: .destructive) { confirmDelete = true }
        } label: {
          HStack(spacing: 5) {
            Circle().fill(style?.enabled == true ? Color.green : Color.secondary.opacity(0.45)).frame(width: 6, height: 6)
            Text(style?.name ?? "Styles").lineLimit(1).font(.system(size: 14, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
          }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Style \(style?.name ?? ""), \(style?.enabled == true ? "on" : "off")")
      }
      Spacer(minLength: 0)
      circleButton("arrow.counterclockwise", "Reset visual controls") { confirmReset = true }
        .disabled(style == nil)
    }
  }

  @ViewBuilder private func notices(_ style: SiteStyle) -> some View {
    if !style.enabled {
      banner("This style is off, so the page is unchanged.", action: "Turn On") { toggleEnabled() }
    } else if !onThisSite, let live = session.liveURL?.host() {
      banner("You’re on \(live). This style is for \(style.hosts.joined(separator: ", ")).", action: "Use the open site") {
        if let url = session.liveURL { session.present(url: url) }
      }
    }
    if showScope { scopeFields(style) }
    if siteStyles.filter(\.enabled).count > 1 {
      Text("Other enabled styles for this site also apply. Later styles win.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func spectrum(_ style: SiteStyle) -> some View {
    StyleSpectrum(color: colorBinding(style.id))
      .focused($spectrumFocused)
      .opacity(style.enabled && style.visualsEnabled ? 1 : 0.45)
      .disabled(!style.enabled || !style.visualsEnabled)
      .accessibilityHint("Arrows change saturation and brightness. Option-arrows change the hue.")
  }

  private func hexRow(_ style: SiteStyle) -> some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Color(red: style.color?.rgb.red ?? 0.75, green: style.color?.rgb.green ?? 0.78, blue: style.color?.rgb.blue ?? 0.82))
        .frame(width: 16, height: 16)
        .overlay(Circle().strokeBorder(StyleChrome.line))
      TextField("Hex", text: $hex)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12, design: .monospaced))
        .focused($hexFocused)
        .onSubmit { applyHex(style.id) }
        .onChange(of: hex) { _, value in if hexFocused { applyHex(style.id, draft: value) } }
        .accessibilityLabel("Hex color")
      Button {
        StyleEditing.update(style.id) { $0.color = nil }
        hex = ""
      } label: {
        Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(.plain)
      .disabled(style.color == nil)
      .accessibilityLabel("Reset color")
      Button {
        StyleEditing.update(style.id) { $0.recolorBoxes.toggle() }
      } label: {
        Text("Boxes")
          .font(.system(size: 11, weight: .semibold))
          .padding(.horizontal, 8)
          .frame(height: 24)
          .background(style.recolorBoxes ? Theme.accent.opacity(0.2) : StyleChrome.button, in: Capsule())
          .overlay(Capsule().strokeBorder(style.recolorBoxes ? Theme.accent : StyleChrome.line))
      }
      .buttonStyle(.plain)
      .help("Recolor nested boxes. Images and video stay as they are. Icon fonts may change.")
      .accessibilityLabel("Recolor nested boxes")
      .accessibilityValue(style.recolorBoxes ? "On" : "Off")
    }
    .disabled(!style.enabled || !style.visualsEnabled)
  }

  private func mainButtons(_ style: SiteStyle) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 14) {
        Spacer(minLength: 0)
        bigButton(style.theme.symbol, "Theme, \(style.theme.title)", section == .theme || style.theme != .website) {
          section = section == .theme ? .none : .theme
        }
        .help("Light, dark, or the website’s own appearance")
        bigButton("slider.horizontal.3", "Contrast, brightness, and saturation", section == .adjust || style.hasAdjustments) {
          section = section == .adjust ? .none : .adjust
        }
        bigButton(style.visualsEnabled ? "circle.slash" : "eye.slash", style.visualsEnabled ? "Turn visual changes off" : "Turn visual changes on", !style.visualsEnabled) {
          StyleEditing.update(style.id) { $0.visualsEnabled.toggle() }
        }
        .help("Turns color, theme, adjustments, font, size, and case off without deleting them. Hidden elements and custom code stay.")
        Spacer(minLength: 0)
      }
      .disabled(!style.enabled)
      Text(paletteCaption(style))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func themeSection(_ style: SiteStyle) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ForEach(StyleTheme.allCases) { theme in
          Button {
            StyleEditing.update(style.id) { $0.theme = theme }
          } label: {
            VStack(spacing: 4) {
              Image(systemName: theme.symbol).font(.system(size: 16))
              Text(theme.title).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(style.theme == theme ? Theme.accent.opacity(0.16) : StyleChrome.button, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style.theme == theme ? Theme.accent : StyleChrome.line))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(theme.title)
          .accessibilityAddTraits(style.theme == theme ? .isSelected : [])
        }
      }
      Text("Light and dark paint a readable background and text. A site that only follows the Mac’s appearance may keep its colors until you pick one or use Code.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func adjustSection(_ style: SiteStyle) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      slider("Contrast", value: double(style.id, \.contrast), range: 0.5...1.8) { StyleEditing.update(style.id) { $0.contrast = 1 } }
      slider("Brightness", value: double(style.id, \.brightness), range: 0.5...1.6) { StyleEditing.update(style.id) { $0.brightness = 1 } }
      slider("Saturation", value: double(style.id, \.saturation), range: 0...2) { StyleEditing.update(style.id) { $0.saturation = 1 } }
      Text("These change the page’s content. Photos and video keep their color when they can be separated. Pinned bars keep their place. This panel is not affected. Full desaturation also turns photos gray.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func fontGrid(_ style: SiteStyle) -> some View {
    let fonts = StyleFonts.available
    let rows = stride(from: 0, to: fonts.count, by: 2).map { Array(fonts[$0..<min($0 + 2, fonts.count)]) }
    return VStack(spacing: 8) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 8) {
          ForEach(row) { font in
            Button {
              StyleEditing.update(style.id) { $0.fontID = style.fontID == font.id ? nil : font.id }
            } label: {
              VStack(spacing: 2) {
                Text("Aa").font(font.sample)
                Text(font.name).font(.system(size: 10)).foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity)
              .frame(height: 58)
              .background(StyleChrome.button, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .strokeBorder(style.fontID == font.id ? Theme.accent : StyleChrome.line, lineWidth: style.fontID == font.id ? 2 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(font.name)
            .accessibilityValue(style.fontID == font.id ? "Selected" : "Not selected")
          }
          if row.count == 1 { Color.clear.frame(maxWidth: .infinity).frame(height: 58) }
        }
      }
    }
    .disabled(!style.enabled || !style.visualsEnabled)
    .opacity(style.enabled && style.visualsEnabled ? 1 : 0.45)
  }

  private func sizeAndCase(_ style: SiteStyle) -> some View {
    HStack(spacing: 8) {
      wideButton(style.textScale == 1 ? "Size" : "Size · \(StyleLimits.percent(style.textScale))", section == .size) {
        section = section == .size ? .none : .size
      }
      .accessibilityLabel("Text size")
      wideButton(style.textCase == .original ? "Case" : "Case · \(style.textCase.sample)", section == .letters) {
        section = section == .letters ? .none : .letters
      }
      .accessibilityLabel("Letter case")
    }
    .disabled(!style.enabled || !style.visualsEnabled)
  }

  private func sizeSection(_ style: SiteStyle) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      slider("Size", value: double(style.id, \.textScale), range: 0.75...1.75) {
        StyleEditing.update(style.id) { $0.textScale = 1 }
      }
      Text("Changes text size on this site. It does not zoom the whole page.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }

  private func caseSection(_ style: SiteStyle) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        ForEach(StyleTextCase.allCases) { mode in
          Button {
            StyleEditing.update(style.id) { $0.textCase = mode }
          } label: {
            Text(mode.sample)
              .font(.system(size: 14, weight: .semibold))
              .frame(maxWidth: .infinity)
              .frame(height: 36)
              .background(style.textCase == mode ? Theme.accent.opacity(0.16) : StyleChrome.button, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.textCase == mode ? Theme.accent : StyleChrome.line))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(mode.title)
        }
      }
      Text("Changes how letters look. The page’s wording stays the same. Code, passwords, and icon fonts are left alone.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private func zapControl(_ style: SiteStyle) -> some View {
    if session.zap == .selecting {
      wideButton("Cancel selection", true) { StyleZap.cancel() }
        .accessibilityLabel("Cancel element selection")
      Text("Click an element to hide it in Comet. Press Escape to cancel. The website itself is not changed.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } else if session.zap == .idle {
      Button {
        StyleZap.begin(style: style)
      } label: {
        Label("Zap", systemImage: "bolt.fill")
          .font(.system(size: 14, weight: .semibold))
          .frame(maxWidth: .infinity)
          .frame(height: 44)
          .background(StyleChrome.button, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StyleChrome.line))
      }
      .buttonStyle(.plain)
      .disabled(!style.enabled || !onThisSite)
      .accessibilityLabel("Zap, hide an element on this site")
    }
  }

  private func confirmZap(_ style: SiteStyle, _ confirmation: ZapConfirmation) -> some View {
    let candidate = confirmation.candidates[confirmation.index]
    return VStack(alignment: .leading, spacing: 8) {
      Text(candidate.label).font(.system(size: 13, weight: .semibold)).lineLimit(2)
      Text(candidate.selector).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
      Text("\(candidate.confidence.title) · \(confirmation.matches) match\(confirmation.matches == 1 ? "" : "es")")
        .font(.system(size: 11))
      if candidate.confidence == .low {
        Text("This selector may break if the page changes. Choose a broader element if that is the one you meant.")
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if confirmation.matches > 8 {
        Text("This will hide \(confirmation.matches) elements.")
          .font(.system(size: 11)).foregroundStyle(.orange)
      }
      HStack {
        Button("Narrower") { StyleZap.choose(confirmation.index - 1, style: style) }.disabled(confirmation.index == 0)
        Button("Broader") { StyleZap.choose(confirmation.index + 1, style: style) }
          .disabled(confirmation.index + 1 >= confirmation.candidates.count)
        Spacer()
        Button("Cancel") { StyleZap.cancel() }
        Button("Hide") { StyleZap.confirm(style: style) }.disabled(confirmation.matches == 0)
      }
      .font(.system(size: 12, weight: .semibold))
      Text("Hidden only in Comet, on this site. It is not removed from the website.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(StyleChrome.button, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  @ViewBuilder private func hiddenList(_ style: SiteStyle) -> some View {
    if !style.hidden.isEmpty {
      DisclosureGroup("Hidden (\(style.hidden.count))") {
        ForEach(style.hidden) { rule in
          HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
              Text(rule.label).lineLimit(1).font(.system(size: 12))
              Text(rule.selector).lineLimit(1).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Restore") {
              StyleEditing.update(style.id) { $0.hidden.removeAll { $0.id == rule.id } }
            }
            .font(.system(size: 11, weight: .semibold))
          }
        }
        Button("Restore All") { StyleEditing.update(style.id) { $0.hidden = [] } }
          .font(.system(size: 12, weight: .semibold))
      }
      .font(.system(size: 12, weight: .semibold))
    }
  }

  private func codeButton(_ style: SiteStyle) -> some View {
    wideButton("Code", session.codeOpen) { openCode(style) }
      .accessibilityLabel("Custom CSS and JavaScript")
  }

  private func scopeFields(_ style: SiteStyle) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Sites", text: hostsBinding(style.id)).textFieldStyle(.roundedBorder).accessibilityLabel("Sites")
      Text("example.com, *.example.com, or https://example.com/docs*. A blank list matches nothing.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      let problems = style.hosts.compactMap(StyleScopeRules.problem)
      if !problems.isEmpty {
        Text(problems.joined(separator: " ")).font(.system(size: 11)).foregroundStyle(.orange)
      }
      TextField("Excluded paths", text: pathsBinding(style.id)).textFieldStyle(.roundedBorder).accessibilityLabel("Excluded paths")
    }
  }

  private func paletteCaption(_ style: SiteStyle) -> String {
    if !style.visualsEnabled { return "Visual changes are off. The values are kept." }
    if style.theme == .website, style.color == nil { return "Pick a color to tint this site’s background, text, and links." }
    if style.recolorBoxes { return "Nested boxes are recolored too. Images and video are left alone." }
    return "Background, text, and links use this color. Boxes on the page may keep their own."
  }

  private func banner(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
      Button(action, action: perform).font(.system(size: 12, weight: .semibold))
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func circleButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .bold))
        .frame(width: 28, height: 28)
        .background(StyleChrome.button, in: Circle())
        .overlay(Circle().strokeBorder(StyleChrome.line))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func bigButton(_ symbol: String, _ label: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 20, weight: .medium))
        .frame(width: 68, height: 68)
        .background(selected ? Theme.accent.opacity(0.14) : StyleChrome.button, in: Circle())
        .overlay(Circle().strokeBorder(selected ? Theme.accent : StyleChrome.line, lineWidth: selected ? 2 : 1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func wideButton(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 14, weight: .semibold))
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(selected ? Theme.accent.opacity(0.14) : StyleChrome.button, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : StyleChrome.line, lineWidth: selected ? 2 : 1))
    }
    .buttonStyle(.plain)
  }

  private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, reset: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title).font(.system(size: 12, weight: .semibold))
        Spacer()
        Text(StyleLimits.percent(value.wrappedValue)).font(.system(size: 12, design: .monospaced)).accessibilityHidden(true)
        Button(action: reset) { Image(systemName: "arrow.counterclockwise") }
          .buttonStyle(.plain)
          .accessibilityLabel("Reset \(title)")
      }
      Slider(value: value, in: range, step: 0.05).accessibilityLabel(title).accessibilityValue(StyleLimits.percent(value.wrappedValue))
    }
  }

  private func colorBinding(_ id: SiteStyle.ID) -> Binding<StyleColor?> {
    Binding(get: { styles.first { $0.id == id }?.color }, set: { value in
      StyleEditing.update(id) { $0.color = value }
      if !hexFocused { hex = value?.rgb.hex ?? "" }
    })
  }

  private func double(_ id: SiteStyle.ID, _ key: WritableKeyPath<SiteStyle, Double>) -> Binding<Double> {
    Binding(get: { styles.first { $0.id == id }?[keyPath: key] ?? 1 }, set: { value in
      StyleEditing.update(id) { $0[keyPath: key] = value }
    })
  }

  private func hostsBinding(_ id: SiteStyle.ID) -> Binding<String> {
    Binding(get: { styles.first { $0.id == id }?.hosts.joined(separator: ", ") ?? "" }, set: { value in
      let hosts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      StyleEditing.update(id) { $0.hosts = hosts }
    })
  }

  private func pathsBinding(_ id: SiteStyle.ID) -> Binding<String> {
    Binding(get: { styles.first { $0.id == id }?.excludedPaths.joined(separator: ", ") ?? "" }, set: { value in
      let paths = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      StyleEditing.update(id) { $0.excludedPaths = paths }
    })
  }

  private func applyHex(_ id: SiteStyle.ID, draft: String? = nil) {
    guard let color = StyleColor(hex: draft ?? hex) else { return }
    StyleEditing.update(id) { $0.color = color }
  }

  private func commitName(_ id: SiteStyle.ID) {
    let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { renaming = false; return }
    StyleEditing.update(id) { $0.name = name }
    renaming = false
  }

  private func toggleEnabled() {
    guard let style else { return }
    StyleEditing.update(style.id, soon: false) { $0.enabled.toggle() }
  }

  private func select(_ id: SiteStyle.ID) {
    guard session.codeIsDirty(in: styles), session.codeStyleID != id else {
      session.styleID = id
      return
    }
    pendingStyle = id
    confirmDiscard = true
  }

  private func discardCode() {
    StyleEngine.draft = nil
    session.codeOpen = false
    if let pendingStyle { session.styleID = pendingStyle }
    self.pendingStyle = nil
    let close = discardClosesPanel
    discardClosesPanel = false
    StyleEngine.applyAll()
    if close { session.dismiss() }
  }

  private func createStyle() {
    guard let url = session.url ?? session.liveURL, let host = url.host()?.lowercased(), !host.isEmpty else { return }
    let style = SiteStyle(id: UUID(), name: host, hosts: [host], enabled: true)
    $styles.withLock { $0.append(style) }
    session.styleID = style.id
    StyleEngine.applyAllSoon()
  }

  private func deleteCurrent() {
    guard let id = style?.id else { return }
    if session.codeStyleID == id {
      StyleEngine.draft = nil
      session.codeOpen = false
    }
    $styles.withLock { $0.removeAll { $0.id == id } }
    session.styleID = siteStyles.first { $0.id != id }?.id
    StyleEngine.applyAll()
  }

  private func openCode(_ style: SiteStyle) {
    if session.codeStyleID != style.id || !session.codeIsDirty(in: styles) {
      session.codeCSS = style.css
      session.codeScript = style.script
      session.codeScriptEnabled = style.scriptEnabled
      session.codeStyleID = style.id
      StyleEngine.draft = nil
    }
    session.codeOpen = true
  }

  private func closePanel() {
    if session.codeIsDirty(in: styles) {
      pendingStyle = nil
      discardClosesPanel = true
      confirmDiscard = true
      return
    }
    session.dismiss()
  }
}

private struct StylePanelHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct StyleCodePanel: View {
  @Bindable private var session = StyleSiteSession.shared
  @Shared(.siteStyles) private var styles
  @State private var diagnostics = StyleDiagnostics.shared
  @State private var language: CSSEditor.Language = .css
  @State private var dragOrigin: CGSize?

  private var style: SiteStyle? {
    if let codeStyleID = session.codeStyleID, let match = styles.first(where: { $0.id == codeStyleID }) { return match }
    return styles.first { $0.id == session.styleID }
  }
  private var dirty: Bool { session.codeIsDirty(in: styles) }
  private var issues: [String] { CSSValidation.issues(in: session.codeCSS) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Code").font(.system(size: 14, weight: .semibold))
        if dirty { Text("Unsaved").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange) }
        Spacer()
        Button { session.codeOpen = false } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain)
          .accessibilityLabel("Close code editor")
      }
      .gesture(drag)
      Text(style?.hosts.joined(separator: ", ").nilIfEmpty ?? "No site yet")
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .accessibilityLabel("Code applies to \(style?.hosts.joined(separator: ", ") ?? "no site")")
      Picker("Language", selection: $language) {
        Text("CSS").tag(CSSEditor.Language.css)
        Text("JavaScript").tag(CSSEditor.Language.javascript)
      }
      .pickerStyle(.segmented)
      .accessibilityLabel("Code language")
      if language == .javascript {
        Text("JavaScript is off until you turn it on for this style. It runs in an isolated world, once each time this site’s page loads. It can read and change the page and this site’s storage. It cannot use Comet’s passwords, keys, or other sites. Timers and listeners it starts through the provided helpers are cleared when the page changes.")
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Toggle("Run JavaScript on this site", isOn: $session.codeScriptEnabled)
          .accessibilityLabel("Run JavaScript on this site")
      }
      CSSEditor(text: language == .css ? $session.codeCSS : $session.codeScript, language: language, label: language == .css ? "CSS" : "JavaScript")
        .frame(minHeight: 220)
      if language == .css, !issues.isEmpty {
        Text(issues.joined(separator: " ")).font(.system(size: 11)).foregroundStyle(.orange).accessibilityLabel("CSS problems")
      }
      if let message = diagnostics.message, message.hasPrefix("Style JavaScript") {
        Text(message).font(.system(size: 11)).foregroundStyle(.orange)
      }
      HStack {
        Button("Preview") { preview() }.disabled(style == nil)
        Button("Save") { save() }.disabled(!dirty || style == nil).keyboardShortcut("s", modifiers: .command)
        Button("Revert") { revert() }.disabled(!dirty)
      }
      .font(.system(size: 12, weight: .semibold))
    }
    .padding(14)
    .foregroundStyle(StyleChrome.ink)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(StyleChrome.background, in: RoundedRectangle(cornerRadius: StyleChrome.radius, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: StyleChrome.radius, style: .continuous).strokeBorder(StyleChrome.line))
    .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Custom code")
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 6)
      .onChanged { value in
        if dragOrigin == nil { dragOrigin = session.codeOffset }
        session.codeOffset = CGSize(
          width: (dragOrigin?.width ?? 0) + value.translation.width,
          height: (dragOrigin?.height ?? 0) + value.translation.height)
        session.codeMoved = true
      }
      .onEnded { _ in dragOrigin = nil }
  }

  private func preview() {
    guard let style else { return }
    StyleEngine.draft = StyleEngine.Draft(
      styleID: style.id, css: session.codeCSS, script: session.codeScript, scriptEnabled: session.codeScriptEnabled)
    StyleEngine.applyAll()
  }

  private func save() {
    guard let style else { return }
    StyleEditing.update(style.id, soon: false) { item in
      item.css = session.codeCSS
      item.script = session.codeScript
      item.scriptEnabled = session.codeScriptEnabled
    }
    StyleEngine.draft = nil
  }

  private func revert() {
    guard let style else { return }
    session.codeCSS = style.css
    session.codeScript = style.script
    session.codeScriptEnabled = style.scriptEnabled
    StyleEngine.draft = nil
    StyleEngine.applyAll()
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct StyleFloatingLayer: NSViewRepresentable {
  var offset: CGSize
  var codeOffset: CGSize
  var styleMoved: Bool
  var codeMoved: Bool
  var codeOpen: Bool
  var contentHeight: CGFloat

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> ClickThroughView {
    let view = ClickThroughView()
    let panel = NSHostingView(rootView: StyleSitePanel())
    panel.sizingOptions = []
    let code = NSHostingView(rootView: StyleCodePanel())
    code.sizingOptions = []
    view.addSubview(panel)
    view.addSubview(code)
    context.coordinator.panel = panel
    context.coordinator.code = code
    return view
  }

  func updateNSView(_ view: ClickThroughView, context: Context) {
    context.coordinator.layout(
      in: view, offset: offset, codeOffset: codeOffset, styleMoved: styleMoved, codeMoved: codeMoved, codeOpen: codeOpen,
      contentHeight: contentHeight)
  }

  final class Coordinator {
    var panel: NSHostingView<StyleSitePanel>?
    var code: NSHostingView<StyleCodePanel>?

    func layout(
      in view: NSView, offset: CGSize, codeOffset: CGSize, styleMoved: Bool, codeMoved: Bool, codeOpen: Bool, contentHeight: CGFloat
    ) {
      let bounds = view.bounds.size
      guard bounds.width > 40, bounds.height > 40 else { return }
      let panelSize = CGSize(width: min(300, max(bounds.width - 24, 220)), height: min(contentHeight + 56, max(180, bounds.height - 16)))
      let origin = StylePanelLayout.styleOrigin(offset: offset, panel: panelSize, bounds: bounds, moved: styleMoved)
      panel?.frame = NSRect(x: origin.x, y: bounds.height - origin.y - panelSize.height, width: panelSize.width, height: panelSize.height)
      let codeSize = CGSize(width: min(460, max(bounds.width - 24, 280)), height: min(540, max(280, bounds.height - 24)))
      let styleFrame = CGRect(origin: origin, size: panelSize)
      let codePoint = StylePanelLayout.codeOrigin(
        offset: codeOffset, panel: codeSize, bounds: bounds, styleFrame: styleFrame, moved: codeMoved)
      code?.frame = NSRect(x: codePoint.x, y: bounds.height - codePoint.y - codeSize.height, width: codeSize.width, height: codeSize.height)
      code?.isHidden = !codeOpen
    }
  }
}

final class ClickThroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

struct StyleSpectrum: View {
  @Binding var color: StyleColor?
  private var hue: Double { color?.hue ?? 0.58 }
  private var saturation: Double { color?.saturation ?? 0.72 }
  private var brightness: Double { color?.brightness ?? 0.85 }

  var body: some View {
    GeometryReader { proxy in
      let rect = CGRect(origin: .zero, size: proxy.size)
      ZStack {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(AngularGradient(colors: stripe, center: .center), lineWidth: 14)
        field(rect.insetBy(dx: 20, dy: 20))
        knob(rect)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { value in
          paint(at: value.location, in: rect)
        })
    }
    .frame(height: 168)
    .focusable()
    .accessibilityElement()
    .accessibilityLabel("Page color")
    .accessibilityValue(color?.rgb.hex ?? "No color")
    .accessibilityAdjustableAction { direction in
      if direction == .increment { store(hue: hue + 0.02, saturation: saturation, brightness: brightness) }
      if direction == .decrement { store(hue: hue - 0.02, saturation: saturation, brightness: brightness) }
    }
    .onKeyPress(phases: [.down, .repeat]) { press in
      let option = press.modifiers.contains(.option)
      switch press.key {
      case .leftArrow:
        option ? store(hue: hue - 0.01, saturation: saturation, brightness: brightness) : store(hue: hue, saturation: saturation - 0.03, brightness: brightness)
      case .rightArrow:
        option ? store(hue: hue + 0.01, saturation: saturation, brightness: brightness) : store(hue: hue, saturation: saturation + 0.03, brightness: brightness)
      case .upArrow: store(hue: hue, saturation: saturation, brightness: brightness + 0.03)
      case .downArrow: store(hue: hue, saturation: saturation, brightness: brightness - 0.03)
      default: return .ignored
      }
      return .handled
    }
  }

  private var stripe: [Color] {
    (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }
  }

  private func field(_ rect: CGRect) -> some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(Color(hue: hue, saturation: 1, brightness: 1))
      .overlay(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
      .overlay(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .padding(20)
      .allowsHitTesting(false)
  }

  private func knob(_ rect: CGRect) -> some View {
    let inner = rect.insetBy(dx: 26, dy: 26)
    let point = CGPoint(x: inner.minX + inner.width * saturation, y: inner.minY + inner.height * (1 - brightness))
    return Circle()
      .fill(Color(red: color?.rgb.red ?? 0.2, green: color?.rgb.green ?? 0.45, blue: color?.rgb.blue ?? 0.85))
      .overlay(Circle().strokeBorder(.white, lineWidth: 2))
      .frame(width: 18, height: 18)
      .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
      .position(point)
      .allowsHitTesting(false)
  }

  private func paint(at point: CGPoint, in rect: CGRect) {
    let inner = rect.insetBy(dx: 18, dy: 18)
    if inner.contains(point) {
      let field = rect.insetBy(dx: 26, dy: 26)
      let x = min(max(0, (point.x - field.minX) / max(field.width, 1)), 1)
      let y = min(max(0, (point.y - field.minY) / max(field.height, 1)), 1)
      store(hue: hue, saturation: x, brightness: 1 - y)
    } else {
      store(hue: hueAt(point, in: rect), saturation: max(saturation, 0.15), brightness: brightness)
    }
  }

  private func store(hue: Double, saturation: Double, brightness: Double) {
    color = StyleColor(hue: hue, saturation: saturation, brightness: brightness)
  }

  private func hueAt(_ point: CGPoint, in rect: CGRect) -> Double {
    let bounds = rect.insetBy(dx: 7, dy: 7)
    var best = 0.0
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for step in 0..<360 {
      let turn = Double(step) / 360
      let sample = perimeter(turn, rect: bounds, radius: 18)
      let distance = hypot(sample.x - point.x, sample.y - point.y)
      if distance < bestDistance {
        bestDistance = distance
        best = turn
      }
    }
    return best
  }

  private func perimeter(_ turn: Double, rect: CGRect, radius: CGFloat) -> CGPoint {
    let radius = min(radius, min(rect.width, rect.height) / 2)
    let width = rect.width - radius * 2
    let height = rect.height - radius * 2
    let arc = CGFloat.pi / 2 * radius
    let total = width * 2 + height * 2 + arc * 4
    var distance = CGFloat(turn) * total
    if distance <= width { return CGPoint(x: rect.minX + radius + distance, y: rect.minY) }
    distance -= width
    if distance <= arc { return arcPoint(distance / arc, center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, start: -.pi / 2) }
    distance -= arc
    if distance <= height { return CGPoint(x: rect.maxX, y: rect.minY + radius + distance) }
    distance -= height
    if distance <= arc { return arcPoint(distance / arc, center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, start: 0) }
    distance -= arc
    if distance <= width { return CGPoint(x: rect.maxX - radius - distance, y: rect.maxY) }
    distance -= width
    if distance <= arc { return arcPoint(distance / arc, center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, start: .pi / 2) }
    distance -= arc
    if distance <= height { return CGPoint(x: rect.minX, y: rect.maxY - radius - distance) }
    distance -= height
    return arcPoint(distance / max(arc, 1), center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, start: .pi)
  }

  private func arcPoint(_ progress: CGFloat, center: CGPoint, radius: CGFloat, start: CGFloat) -> CGPoint {
    let angle = start + progress * .pi / 2
    return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
  }
}
