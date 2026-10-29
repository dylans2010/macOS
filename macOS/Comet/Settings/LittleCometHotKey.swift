import Carbon
import ComposableArchitecture

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  static var littleCometHotKey: Self { Self[.appStorage("littleCometHotKey"), default: true] }
}

// ⌥⌘N in any app: a system-wide hot key that opens a Little Comet while the setting is on.
@MainActor
final class LittleCometHotKey {
  @Shared(.littleCometHotKey) private var isEnabled
  private let action: () -> Void
  private var hotKey: EventHotKeyRef?
  private var token: ObserveToken?

  init(action: @escaping () -> Void) {
    self.action = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, data in
        MainActor.assumeIsolated { Unmanaged<LittleCometHotKey>.fromOpaque(data!).takeUnretainedValue().action() }
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    token = observe { [weak self] in self?.update() }
  }

  private func update() {
    if isEnabled, hotKey == nil {
      let id = EventHotKeyID(signature: OSType(0x4C_41_52_43), id: 1)
      RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    } else if !isEnabled, let hotKey {
      UnregisterEventHotKey(hotKey)
      self.hotKey = nil
    }
  }
}
