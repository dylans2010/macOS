import ComposableArchitecture
import SwiftUI

enum TabLayoutMode: String, CaseIterable, Codable, Sendable {
  case vertical
  case horizontal

  var title: String {
    switch self {
    case .vertical: "Vertical"
    case .horizontal: "Horizontal"
    }
  }
}

extension SharedKey where Self == AppStorageKey<String>.Default {
  static var tabLayout: Self { Self[.appStorage("tabLayout"), default: TabLayoutMode.vertical.rawValue] }
}

struct TabLayoutPane: View {
  @Shared(.tabLayout) private var layout

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Tab layout").font(.system(size: 13, weight: .semibold))
      Picker("Layout", selection: Binding(
        get: { TabLayoutMode(rawValue: layout) ?? .vertical },
        set: { mode in $layout.withLock { $0 = mode.rawValue } }
      )) {
        ForEach(TabLayoutMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
      }
      .pickerStyle(.segmented)
      Text("Horizontal and vertical tabs use the same tabs, Spaces, pins, and history. Switching layout does not reload pages.")
        .font(.system(size: 12)).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(24)
  }
}

struct HorizontalTabStrip: View {
  let store: StoreOf<WindowFeature>
  private var space: Space { store.spaces.selected }
  private var tabs: [Tab] { space.tabs(in: .pinned) + space.tabs(in: .unpinned) }

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 4) {
        ForEach(tabs) { tab in
          tabButton(tab)
        }
        Button {
          store.send(.showCommandBar)
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("New Tab")
        .accessibilityLabel("New Tab")
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .frame(height: 40)
    .background(.black.opacity(0.18))
  }

  private func tabButton(_ tab: Tab) -> some View {
    let selected = tab.id == space.selectedTabID
    return HStack(spacing: 6) {
      if let icon = tab.favicon {
        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
      }
      Text(tab.isLive ? tab.displayTitle : "\(tab.displayTitle) · sleeping")
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .lineLimit(1)
        .frame(maxWidth: tab.placement == .pinned ? 72 : 160, alignment: .leading)
      if tab.isLoading {
        ProgressView().controlSize(.small)
      }
      if tab.isAudible {
        Image(systemName: tab.isMuted ? "speaker.slash" : "speaker.wave.2").font(.system(size: 10))
      }
      Button {
        store.send(.tab(.close(tab.id), in: space.id))
      } label: {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
      }
      .buttonStyle(.plain)
      .opacity(selected ? 1 : 0.45)
      .accessibilityLabel("Close \(tab.displayTitle)")
    }
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(selected ? Color.white.opacity(0.16) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    .contentShape(Rectangle())
    .onTapGesture { store.send(.tab(.select(tab.id), in: space.id)) }
    .contextMenu {
      Button(tab.placement == .pinned ? "Unpin" : "Pin") {
        store.send(.tab(.togglePin(tab.id), in: space.id))
      }
      Button("Duplicate") { store.send(.tab(.duplicate(tab.id), in: space.id)) }
      Button("Reload") { store.send(.tab(.select(tab.id), in: space.id)); store.send(.tab(.reload, in: space.id)) }
      Button(tab.isMuted ? "Unmute" : "Mute") { store.send(.tab(.toggleMute(tab.id), in: space.id)) }
      Button("Close") { store.send(.tab(.close(tab.id), in: space.id)) }
    }
    .accessibilityLabel(tab.displayTitle)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .gesture(drag(tab))
  }

  private func drag(_ tab: Tab) -> some Gesture {
    DragGesture(minimumDistance: 8).onEnded { value in
      guard tab.placement == .unpinned else { return }
      let today = space.tabs(in: .unpinned)
      guard let index = today.firstIndex(where: { $0.id == tab.id }) else { return }
      let delta = Int((value.translation.width / 120).rounded())
      let next = min(max(index + delta, 0), today.count - 1)
      guard next != index else { return }
      let before = next > index ? today[min(next + 1, today.count - 1)].id : today[next].id
      let target = next == today.count - 1 && delta > 0 ? nil : before
      store.send(.tab(.move(tab.id, .unpinned, before: target == tab.id ? nil : target), in: space.id))
    }
  }
}
