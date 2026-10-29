import AppKit
import ComposableArchitecture
import SwiftUI

extension URL {
  static let cometStart = URL(string: "comet-start://home")!
  var isCometStart: Bool { scheme?.lowercased() == "comet-start" }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  static var opensStartPage: Self { Self[.appStorage("opensStartPage"), default: false] }
}

struct StartLink: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var url: String

  static func normalized(_ raw: String) -> URL? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") { text = "https://" + text }
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil
    else { return nil }
    return url
  }
}

struct StartQuote: Codable, Equatable, Sendable {
  var text: String
  var author: String
  var source: String
}

enum QuoteLibrary {
  static let builtIn: [StartQuote] = [
    StartQuote(text: "The only thing we have to fear is fear itself.", author: "Franklin D. Roosevelt", source: "First inaugural address, 1933"),
    StartQuote(text: "I went to the woods because I wished to live deliberately.", author: "Henry David Thoreau", source: "Walden"),
    StartQuote(text: "We know what we are, but know not what we may be.", author: "William Shakespeare", source: "Hamlet"),
    StartQuote(text: "I contain multitudes.", author: "Walt Whitman", source: "Song of Myself"),
  ]

  static func daily(on date: Date = .now, extra: [StartQuote]) -> StartQuote? {
    let pool = builtIn + extra
    guard !pool.isEmpty else { return nil }
    let day = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
    return pool[(day - 1) % pool.count]
  }
}

struct PomodoroSettings: Codable, Equatable, Sendable {
  var workMinutes = 25
  var breakMinutes = 5
  var endsAt: Date?
  var isBreak = false
  var running = false
}

struct StartPageSettings: Codable, Equatable, Sendable {
  var displayName = ""
  var greeting = ""
  var use24Hour = false
  var showSeconds = false
  var showClock = true
  var showGreeting = true
  var showLinks = true
  var showSearch = true
  var showNotes = true
  var showWeather = false
  var showQuote = false
  var showTimer = false
  var city = ""
  var useCelsius = true
  var links: [StartLink] = []
  var notes = ""
  var quotes: [StartQuote] = []
  var backgroundName = "Dusk"
  var backgroundPath = ""
  var dim = 0.35
  var accent = "#E8E4DC"
  var pomodoro = PomodoroSettings()
}

extension SharedKey where Self == FileStorageKey<StartPageSettings>.Default {
  static var startPage: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "StartPage.json")), default: StartPageSettings()]
  }
}

enum StartBackground: String, CaseIterable, Identifiable {
  case dusk = "Dusk"
  case paper = "Paper"
  case ink = "Ink"
  case tide = "Tide"
  var id: String { rawValue }
  var colors: [Color] {
    switch self {
    case .dusk: [Color(hex: 0x1B2430), Color(hex: 0x3D2B3A)]
    case .paper: [Color(hex: 0xF4EFE6), Color(hex: 0xE4D5C4)]
    case .ink: [Color(hex: 0x121417), Color(hex: 0x1E242C)]
    case .tide: [Color(hex: 0x14343C), Color(hex: 0x1E4D4A)]
    }
  }
}

enum WeatherReport: Equatable {
  struct Conditions: Equatable { var place: String; var temperature: Double; var summary: String }
}

enum WeatherClient {
  static func parsePlace(_ data: Data) -> (name: String, latitude: Double, longitude: Double)? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let results = json["results"] as? [[String: Any]],
      let first = results.first,
      let name = first["name"] as? String,
      let latitude = first["latitude"] as? Double,
      let longitude = first["longitude"] as? Double
    else { return nil }
    return (name, latitude, longitude)
  }

  static func parseConditions(_ data: Data) -> (temperature: Double, code: Int)? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let current = json["current"] as? [String: Any],
      let temperature = current["temperature_2m"] as? Double,
      let code = current["weather_code"] as? Int
    else { return nil }
    return (temperature, code)
  }

  static func summary(for code: Int) -> String {
    switch code {
    case 0: "Clear"
    case 1, 2: "Partly cloudy"
    case 3: "Cloudy"
    case 45, 48: "Fog"
    case 51, 53, 55, 61, 63, 65, 80, 81, 82: "Rain"
    case 71, 73, 75, 77, 85, 86: "Snow"
    case 95, 96, 99: "Thunderstorm"
    default: "Weather code \(code)"
    }
  }

  static func fetch(city: String) async throws -> WeatherReport.Conditions {
    var geocode = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
    geocode.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
    let (placeData, placeResponse) = try await URLSession.shared.data(from: geocode.url!)
    guard let http = placeResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let place = parsePlace(placeData)
    else { throw URLError(.cannotParseResponse) }
    var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    forecast.queryItems = [
      URLQueryItem(name: "latitude", value: String(place.latitude)),
      URLQueryItem(name: "longitude", value: String(place.longitude)),
      URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
    ]
    let (forecastData, forecastResponse) = try await URLSession.shared.data(from: forecast.url!)
    guard let forecastHTTP = forecastResponse as? HTTPURLResponse, (200..<300).contains(forecastHTTP.statusCode),
      let conditions = parseConditions(forecastData)
    else { throw URLError(.cannotParseResponse) }
    return WeatherReport.Conditions(place: place.name, temperature: conditions.temperature, summary: summary(for: conditions.code))
  }
}

struct StartPageView: View {
  let open: (URL) -> Void
  @Shared(.startPage) private var settings
  @State private var query = ""
  @State private var weather: WeatherReport.Conditions?
  @State private var weatherError: String?
  @State private var editing = false
  @State private var linkTitle = ""
  @State private var linkURL = ""

  var body: some View {
    ZStack {
      background
      Color.black.opacity(settings.dim).allowsHitTesting(false)
      ScrollView {
        VStack(spacing: 22) {
          if settings.showClock { clock }
          if settings.showGreeting { greeting }
          if settings.showSearch { search }
          if settings.showLinks { links }
          if settings.showWeather { weatherBlock }
          if settings.showQuote { quoteBlock }
          if settings.showTimer { timer }
          if settings.showNotes { notes }
          Button("Customize Start Page") { editing = true }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(36)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
      }
    }
    .sheet(isPresented: $editing) { StartPageEditor() }
    .task(id: settings.city) { await loadWeather() }
  }

  private var background: some View {
    Group {
      if let image = NSImage(contentsOfFile: settings.backgroundPath) {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        LinearGradient(
          colors: StartBackground(rawValue: settings.backgroundName)?.colors ?? StartBackground.dusk.colors,
          startPoint: .topLeading, endPoint: .bottomTrailing)
      }
    }
    .ignoresSafeArea()
  }

  private var clock: some View {
    TimelineView(.periodic(from: .now, by: settings.showSeconds ? 1 : 30)) { context in
      Text(clockText(context.date))
        .font(.system(size: 64, weight: .medium, design: .rounded))
        .foregroundStyle(Color(hexString: settings.accent))
        .accessibilityLabel(clockText(context.date))
    }
  }

  private func clockText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateFormat = settings.showSeconds
      ? (settings.use24Hour ? "HH:mm:ss" : "h:mm:ss a")
      : (settings.use24Hour ? "HH:mm" : "h:mm a")
    return formatter.string(from: date)
  }

  private var greeting: some View {
    let hour = Calendar.current.component(.hour, from: .now)
    let hello = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    let name = settings.displayName.trimmingCharacters(in: .whitespaces)
    let custom = settings.greeting.trimmingCharacters(in: .whitespaces)
    return Text(custom.isEmpty ? (name.isEmpty ? hello : "\(hello), \(name)") : custom)
      .font(.system(size: 22, weight: .medium))
      .foregroundStyle(.white)
  }

  private var search: some View {
    TextField("Search or enter an address", text: $query)
      .textFieldStyle(.plain)
      .padding(12)
      .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
      .foregroundStyle(.white)
      .onSubmit {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.contains(".") || text.contains("://"), let url = StartLink.normalized(text) {
          open(url)
        } else {
          open(CommandBarFeature.searchURL(text))
        }
        query = ""
      }
  }

  private var links: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Links").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
        Spacer()
      }
      ForEach(settings.links) { link in
        HStack {
          Button(link.title) {
            if let url = StartLink.normalized(link.url) { open(url) }
          }
          .buttonStyle(.plain)
          .foregroundStyle(.white)
          Spacer()
          Button("Remove") { $settings.withLock { $0.links.removeAll { $0.id == link.id } } }
            .font(.system(size: 11))
        }
      }
      HStack {
        TextField("Title", text: $linkTitle).textFieldStyle(.roundedBorder)
        TextField("https://", text: $linkURL).textFieldStyle(.roundedBorder)
        Button("Add") {
          guard let url = StartLink.normalized(linkURL) else { return }
          let title = linkTitle.trimmingCharacters(in: .whitespaces).isEmpty ? url.host() ?? "Link" : linkTitle
          $settings.withLock { $0.links.append(StartLink(id: UUID(), title: title, url: url.absoluteString)) }
          linkTitle = ""
          linkURL = ""
        }
      }
    }
  }

  private var weatherBlock: some View {
    VStack(alignment: .leading, spacing: 4) {
      if settings.city.trimmingCharacters(in: .whitespaces).isEmpty {
        Text("Add a city in Customize to show weather. Location is not used.").foregroundStyle(.white.opacity(0.75))
      } else if let weather {
        let degrees = settings.useCelsius ? weather.temperature : weather.temperature * 9 / 5 + 32
        Text("\(weather.place) · \(Int(degrees.rounded()))° \(settings.useCelsius ? "C" : "F") · \(weather.summary)")
          .foregroundStyle(.white)
      } else if let weatherError {
        Text(weatherError).foregroundStyle(.white.opacity(0.75))
      } else {
        Text("Looking up \(settings.city)…").foregroundStyle(.white.opacity(0.75))
      }
    }
    .font(.system(size: 14))
  }

  private var quoteBlock: some View {
    Group {
      if let quote = QuoteLibrary.daily(extra: settings.quotes) {
        VStack(alignment: .leading, spacing: 4) {
          Text("“\(quote.text)”").foregroundStyle(.white)
          Text("\(quote.author) · \(quote.source)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
        }
      }
    }
  }

  private var timer: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let remaining = settings.pomodoro.endsAt.map { max(0, $0.timeIntervalSince(context.date)) } ?? 0
      VStack(spacing: 6) {
        Text(settings.pomodoro.running ? (settings.pomodoro.isBreak ? "Break" : "Focus") : "Timer")
          .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
        Text(time(remaining)).font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(.white)
          .accessibilityLabel("Timer \(time(remaining))")
        HStack {
          Button(settings.pomodoro.running ? "Pause" : "Start") { toggleTimer() }
          Button("Reset") { $settings.withLock { $0.pomodoro.running = false; $0.pomodoro.endsAt = nil; $0.pomodoro.isBreak = false } }
        }
        .buttonStyle(.bordered)
      }
      .onChange(of: context.date) { _, date in
        guard settings.pomodoro.running, let end = settings.pomodoro.endsAt, date >= end else { return }
        $settings.withLock {
          $0.pomodoro.isBreak.toggle()
          let minutes = $0.pomodoro.isBreak ? $0.pomodoro.breakMinutes : $0.pomodoro.workMinutes
          $0.pomodoro.endsAt = date.addingTimeInterval(TimeInterval(minutes * 60))
        }
      }
    }
  }

  private var notes: some View {
    TextEditor(text: notesBinding)
      .font(.system(size: 14))
      .scrollContentBackground(.hidden)
      .frame(minHeight: 90)
      .padding(8)
      .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
      .foregroundStyle(.white)
  }

  private var notesBinding: Binding<String> {
    Binding(get: { settings.notes }, set: { value in $settings.withLock { $0.notes = value } })
  }

  private func toggleTimer() {
    $settings.withLock { page in
      if page.pomodoro.running {
        page.pomodoro.running = false
        page.pomodoro.endsAt = nil
      } else {
        let minutes = page.pomodoro.isBreak ? page.pomodoro.breakMinutes : page.pomodoro.workMinutes
        page.pomodoro.running = true
        page.pomodoro.endsAt = Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60))
      }
    }
  }

  private func time(_ interval: TimeInterval) -> String {
    let total = Int(interval)
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  private func loadWeather() async {
    let city = settings.city.trimmingCharacters(in: .whitespacesAndNewlines)
    guard settings.showWeather, !city.isEmpty else { weather = nil; weatherError = nil; return }
    do {
      weather = try await WeatherClient.fetch(city: city)
      weatherError = nil
    } catch {
      weather = nil
      weatherError = "Weather for \(city) could not be loaded."
    }
  }
}

struct StartPageEditor: View {
  @Shared(.startPage) private var settings
  @Shared(.opensStartPage) private var opensStartPage
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("Customize Start Page").font(.headline)
        SettingsToggle("Open this page for new tabs", isOn: $opensStartPage)
        TextField("Name", text: string(\.displayName)).textFieldStyle(.roundedBorder)
        TextField("Greeting (blank uses the time of day)", text: string(\.greeting)).textFieldStyle(.roundedBorder)
        Toggle("24-hour clock", isOn: bool(\.use24Hour))
        Toggle("Show seconds", isOn: bool(\.showSeconds))
        Toggle("Clock", isOn: bool(\.showClock))
        Toggle("Greeting", isOn: bool(\.showGreeting))
        Toggle("Search", isOn: bool(\.showSearch))
        Toggle("Links", isOn: bool(\.showLinks))
        Toggle("Notes", isOn: bool(\.showNotes))
        Toggle("Weather", isOn: bool(\.showWeather))
        TextField("City for weather", text: string(\.city)).textFieldStyle(.roundedBorder)
        Text("Weather uses Open-Meteo for the city you type. Comet does not request your location.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        Toggle("Celsius", isOn: bool(\.useCelsius))
        Toggle("Quote", isOn: bool(\.showQuote))
        Toggle("Timer", isOn: bool(\.showTimer))
        Picker("Background", selection: background) {
          ForEach(StartBackground.allCases) { item in Text(item.rawValue).tag(item.rawValue) }
        }
        Button("Choose Image…", action: chooseImage)
        HStack {
          Text("Dim")
          Slider(value: dim, in: 0...0.7)
        }
        HStack {
          Button("Export…", action: exportSettings)
          Button("Import…", action: importSettings)
          Button("Reset") { $settings.withLock { $0 = StartPageSettings() } }
          Spacer()
          Button("Done") { dismiss() }
        }
      }
      .padding(20)
      .frame(width: 460)
    }
  }

  private var background: Binding<String> {
    Binding(get: { settings.backgroundName }, set: { value in $settings.withLock { $0.backgroundName = value; $0.backgroundPath = "" } })
  }

  private var dim: Binding<Double> {
    Binding(get: { settings.dim }, set: { value in $settings.withLock { $0.dim = value } })
  }

  private func string(_ key: WritableKeyPath<StartPageSettings, String>) -> Binding<String> {
    Binding(get: { settings[keyPath: key] }, set: { value in $settings.withLock { $0[keyPath: key] = value } })
  }

  private func bool(_ key: WritableKeyPath<StartPageSettings, Bool>) -> Binding<Bool> {
    Binding(get: { settings[keyPath: key] }, set: { value in $settings.withLock { $0[keyPath: key] = value } })
  }

  private func chooseImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let destination = URL.dataDirectory.appending(path: "StartBackground")
    try? FileManager.default.removeItem(at: destination)
    try? FileManager.default.copyItem(at: url, to: destination)
    $settings.withLock { $0.backgroundPath = destination.path }
  }

  private func exportSettings() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Comet Start Page.json"
    guard panel.runModal() == .OK, let url = panel.url, let data = try? JSONEncoder().encode(settings) else { return }
    try? data.write(to: url)
  }

  private func importSettings() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(StartPageSettings.self, from: data)
    else { return }
    $settings.withLock { $0 = decoded }
  }
}

private extension Color {
  init(hexString: String) {
    var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard let value = UInt32(hex, radix: 16) else { self = .white; return }
    self.init(hex: value)
  }
}
