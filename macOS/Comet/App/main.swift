import AppKit
import ComposableArchitecture
import EngineCore
import Security

if isTesting {
  NSApplication.shared.run()
} else {
  // The Anthropic API key and setting the removed Settings > AI kept.
  SecItemDelete(
    [kSecClass: kSecClassGenericPassword, kSecAttrService: "\(Bundle.main.bundleIdentifier!).anthropic-api-key"]
      as CFDictionary)
  UserDefaults.standard.removeObject(forKey: "tidyTabTitles")
  // Settings and files saved under Little Comet's former names (Little Arc, then Little Sailfish).
  for (old, new) in [
    ("littleArcHintShown", "littleCometHintShown"), ("littleArcStaysOnTop", "littleCometStaysOnTop"),
    ("littleArcHotKey", "littleCometHotKey"), ("littleArcsOnOptionCommandClick", "littleCometOnOptionCommandClick"),
    ("littleSailfishHintShown", "littleCometHintShown"), ("littleSailfishStaysOnTop", "littleCometStaysOnTop"),
    ("littleSailfishHotKey", "littleCometHotKey"), ("littleSailfishOnOptionCommandClick", "littleCometOnOptionCommandClick"),
  ] {
    if let value = UserDefaults.standard.object(forKey: old) {
      UserDefaults.standard.set(value, forKey: new)
      UserDefaults.standard.removeObject(forKey: old)
    }
  }
  for oldName in ["LittleArcProfiles.json", "LittleSailfishProfiles.json"] {
    try? FileManager.default.moveItem(
      at: URL.dataDirectory.appending(path: oldName),
      to: URL.dataDirectory.appending(path: "LittleCometProfiles.json"))
  }
  let routes = URL.dataDirectory.appending(path: "LinkRoutes.json")
  if var json = try? String(contentsOf: routes, encoding: .utf8),
    json.contains("\"littleArc\"") || json.contains("\"littleSailfish\"")
  {
    json = json.replacingOccurrences(of: "\"littleArc\"", with: "\"littleComet\"")
    json = json.replacingOccurrences(of: "\"littleSailfish\"", with: "\"littleComet\"")
    try json.write(to: routes, atomically: true, encoding: .utf8)
  }
  let shell = Shell()
  let center = NotificationCenter.default
  center.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { shell.launch() }
  }
  center.addObserver(forName: .ECEngineOpenURLs, object: nil, queue: .main) { notification in
    let urls = notification.object as! [URL]
    MainActor.assumeIsolated { _ = shell.store.send(.openURLs(urls)) }
  }
  center.addObserver(forName: .ECEngineReopen, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { _ = shell.store.send(.reopen) }
  }
  center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { shell.terminate() }
  }
  ECEngine.start(withArguments: CommandLine.arguments + ["--user-data-dir=" + Engine.userDataDir])
}
