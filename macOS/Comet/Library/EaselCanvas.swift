import AppKit
import ComposableArchitecture
import EngineCore
import SwiftUI
import UniformTypeIdentifiers

enum EaselTool: String, CaseIterable {
  case select, text, link, image, capture, draw

  var symbol: String {
    switch self {
    case .select: "cursorarrow"
    case .text: "text.alignleft"
    case .link: "link"
    case .image: "photo"
    case .capture: "camera"
    case .draw: "pencil.tip"
    }
  }

  var help: String {
    switch self {
    case .select: "Select"
    case .text: "Text"
    case .link: "Link"
    case .image: "Image"
    case .capture: "Capture Page"
    case .draw: "Draw"
    }
  }
}

struct EaselCanvas: View {
  let easel: Easel
  let space: Space
  let open: (URL, Bool) -> Void
  let toast: (String) -> Void

  @Shared(.easels) private var easels
  @State private var tool = EaselTool.select
  @State private var selection: CanvasObject.ID?
  @State private var editingText: CanvasObject.ID?
  @State private var undoStack: [Easel] = []
  @State private var redoStack: [Easel] = []
  @State private var drag: Drag?
  @State private var liveStroke: [StrokePoint] = []
  @State private var strokeColor: UInt32 = 0xEDEDF2
  @State private var strokeWidth = 3.0
  @State private var spaceHold = SpaceHold()
  @State private var images: [UUID: NSImage] = [:]
  @FocusState private var isFocused: Bool

  private var current: Easel { easels[id: easel.id] ?? easel }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      GeometryReader { proxy in
        let transform = Transform(origin: CGPoint(x: current.originX, y: current.originY), zoom: current.zoom, size: proxy.size)
        ZStack(alignment: .topLeading) {
          Theme.fill.opacity(0.35)
          CanvasEventCatcher(onScroll: { pan(by: $0) }, onMagnify: { zoom(by: $0, around: nil) })
          canvasLayer(transform)
          connectorLayer(transform)
          objectsLayer(transform)
          if liveStroke.count > 1 {
            liveStrokePath(transform)
          }
          if let id = selection, let object = current.objects[id: id], object.kind != .stroke {
            handles(object, transform: transform)
          }
        }
        .contentShape(Rectangle())
        .onTapGesture { location in tap(location, transform: transform) }
        .gesture(primaryDrag(transform))
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers, location in
          drop(providers, at: transform.toCanvas(location))
        }
        .contextMenu { canvasMenu(transform) }
      }
      .clipped()
      .focusable()
      .focused($isFocused)
      .onKeyPress(.escape) {
        editingText = nil
        selection = nil
        tool = .select
        return .handled
      }
      .onKeyPress(.delete, action: deleteSelected)
      .onKeyPress { press in
        if press.characters.lowercased() == "z", press.modifiers.contains(.command) {
          if press.modifiers.contains(.shift) { redo() } else { undo() }
          return .handled
        }
        if editingText == nil, press.characters.lowercased() == "v", press.modifiers.contains(.command) {
          paste(at: nil)
          return .handled
        }
        guard editingText == nil, selection != nil else { return .ignored }
        switch press.key {
        case .leftArrow: nudge(-8, 0); return .handled
        case .rightArrow: nudge(8, 0); return .handled
        case .upArrow: nudge(0, -8); return .handled
        case .downArrow: nudge(0, 8); return .handled
        default: return .ignored
        }
      }
    }
    .onAppear {
      isFocused = true
      loadImages()
      spaceHold.start()
    }
    .onDisappear { spaceHold.stop() }
    .onChange(of: current.objects.map(\.mediaID)) { _, _ in loadImages() }
  }

  private var toolbar: some View {
    HStack(spacing: 4) {
      ForEach(EaselTool.allCases, id: \.self) { item in
        toolButton(item)
      }
      if tool == .draw {
        Divider().frame(height: 18).padding(.horizontal, 4)
        ForEach(Self.swatches, id: \.self) { color in
          Button {
            strokeColor = color
          } label: {
            Circle().fill(Color(hex: color)).frame(width: 14, height: 14)
              .overlay(Circle().strokeBorder(.white.opacity(strokeColor == color ? 0.9 : 0.25), lineWidth: strokeColor == color ? 2 : 1))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Stroke color")
        }
        ForEach([2.0, 3.0, 6.0], id: \.self) { width in
          Button {
            strokeWidth = width
          } label: {
            Capsule().fill(Theme.primaryText.opacity(strokeWidth == width ? 1 : 0.35)).frame(width: 10 + width * 2, height: width + 2)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Stroke width \(Int(width))")
        }
      }
      Spacer(minLength: 8)
      toolButton(systemName: "arrow.uturn.backward", help: "Undo", enabled: !undoStack.isEmpty, action: undo)
      toolButton(systemName: "arrow.uturn.forward", help: "Redo", enabled: !redoStack.isEmpty, action: redo)
      Divider().frame(height: 18).padding(.horizontal, 4)
      toolButton(systemName: "minus.magnifyingglass", help: "Zoom Out") { zoom(by: 0.85, around: nil) }
      Button("\(Int((current.zoom * 100).rounded()))%") { resetView() }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .help("Reset View")
      toolButton(systemName: "plus.magnifyingglass", help: "Zoom In") { zoom(by: 1.15, around: nil) }
    }
    .padding(.horizontal, 12)
    .frame(height: 40)
  }

  private static let swatches: [UInt32] = [0xEDEDF2, 0x14191C, 0x1D7DAF, 0xE8432A, 0xE8C44A, 0x3D9A5B]

  private func toolButton(_ item: EaselTool) -> some View {
    Button {
      if item == .image { pickImages() }
      else if item == .capture { capturePage() }
      else { tool = item }
    } label: {
      Image(systemName: item.symbol).font(.system(size: 13, weight: .medium))
        .foregroundStyle(tool == item ? Theme.primaryText : Theme.icon)
        .frame(width: 28, height: 28)
        .background(tool == item ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(item.help)
    .accessibilityLabel(item.help)
    .accessibilityAddTraits(tool == item ? .isSelected : [])
  }

  private func toolButton(systemName: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.icon)
        .frame(width: 28, height: 28).contentShape(Rectangle()).opacity(enabled ? 1 : 0.35)
    }
    .buttonStyle(.plain)
    .help(help)
    .disabled(!enabled)
    .accessibilityLabel(help)
  }

  private func canvasLayer(_ transform: Transform) -> some View {
    Canvas { context, size in
      drawGrid(context, transform: transform, size: size)
      for object in current.objects where object.kind == .stroke {
        guard let stroke = object.stroke, let path = Self.path(stroke, transform: transform) else { continue }
        context.stroke(
          path, with: .color(Color(hex: stroke.color)),
          style: StrokeStyle(lineWidth: stroke.width * transform.zoom, lineCap: .round, lineJoin: .round))
      }
      if let id = selection, let object = current.objects[id: id] {
        let rect = transform.rect(object.frame).insetBy(dx: -3, dy: -3)
        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(Theme.accent), lineWidth: 2)
      }
    }
    .allowsHitTesting(false)
  }

  private func connectorLayer(_ transform: Transform) -> some View {
    Canvas { context, _ in
      for object in current.objects where object.kind == .connector {
        guard let from = object.fromID.flatMap({ current.objects[id: $0] }),
          let to = object.toID.flatMap({ current.objects[id: $0] })
        else { continue }
        var path = Path()
        let start = transform.toScreen(CGPoint(x: from.x + from.width / 2, y: from.y + from.height / 2))
        let end = transform.toScreen(CGPoint(x: to.x + to.width / 2, y: to.y + to.height / 2))
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
        if !object.relation.isEmpty {
          context.draw(Text(object.relation).font(.system(size: 11)), at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
        }
      }
    }
    .allowsHitTesting(false)
  }

  private func objectsLayer(_ transform: Transform) -> some View {
    let visible = transform.visibleRect.insetBy(dx: -80, dy: -80)
    return ForEach(current.objects) { object in
      if object.kind != .stroke, object.kind != .connector, object.frame.intersects(visible) {
        objectView(object, transform: transform)
          .frame(width: object.width * transform.zoom, height: object.height * transform.zoom)
          .position(transform.toScreen(CGPoint(x: object.x + object.width / 2, y: object.y + object.height / 2)))
      }
    }
  }

  @ViewBuilder private func objectView(_ object: CanvasObject, transform: Transform) -> some View {
    switch object.kind {
    case .text:
      Group {
        if editingText == object.id {
          TextEditor(text: textBinding(object))
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(6)
        } else {
          Text(NoteMarkdown.attributed(object.text.isEmpty ? "Text" : object.text))
            .font(.system(size: 14))
            .foregroundStyle(object.text.isEmpty ? Theme.secondaryText : Theme.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
        }
      }
      .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
      .onTapGesture(count: 2) { editingText = object.id; selection = object.id }
    case .link:
      LinkCard(object: object, profile: space.profileID, open: { object.url.map { open($0, false) } })
    case .image, .capture:
      MediaCard(object: object, image: object.mediaID.flatMap { images[$0] }, open: { object.url.map { open($0, false) } })
    case .stroke, .connector:
      EmptyView()
    case .note:
      VStack(alignment: .leading, spacing: 4) {
        Label(object.title.isEmpty ? "Note" : object.title, systemImage: "note.text")
          .font(.system(size: 13, weight: .semibold))
        Text(object.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
      }
      .padding(8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
    }
  }

  private func liveStrokePath(_ transform: Transform) -> some View {
    Path { path in
      guard let first = liveStroke.first else { return }
      path.move(to: transform.toScreen(CGPoint(x: first.x, y: first.y)))
      for point in liveStroke.dropFirst() {
        path.addLine(to: transform.toScreen(CGPoint(x: point.x, y: point.y)))
      }
    }
    .stroke(Color(hex: strokeColor), style: StrokeStyle(lineWidth: strokeWidth * current.zoom, lineCap: .round, lineJoin: .round))
    .allowsHitTesting(false)
  }

  private func handles(_ object: CanvasObject, transform: Transform) -> some View {
    let rect = transform.rect(object.frame)
    return ForEach(Corner.allCases, id: \.self) { corner in
      let point = corner.point(in: rect)
      Circle().fill(Theme.accent).frame(width: 8, height: 8)
        .position(x: point.x, y: point.y)
        .gesture(
          DragGesture()
            .onChanged { value in
              if drag == nil { drag = .resize(id: object.id, corner: corner, start: value.startLocation, origin: object.frame) }
              resize(to: value.location, transform: transform)
            }
            .onEnded { _ in drag = nil }
        )
    }
  }

  private func addTemplate(_ name: String) {
    Easels.update(easel.id) { board in
      for object in EaselTemplates.named(name) where object.isValid { board.add(object) }
    }
  }

  private func canvasMenu(_ transform: Transform) -> some View {
    Group {
      Button("Paste") { paste(at: nil) }
      Divider()
      Button("Add Text") { addText(at: nil) }
      Button("Add Link…") { addLink(at: nil) }
      Button("Add Image…") { pickImages() }
      Button("Capture Page") { capturePage() }
      Menu("Template") {
        Button("Website research") { addTemplate("Website research") }
        Button("Comparison") { addTemplate("Comparison") }
        Button("Brainstorm") { addTemplate("Brainstorm") }
      }
      if let id = selection, let object = current.objects[id: id] {
        Divider()
        if let url = object.url {
          Button("Open Source Page") { open(url, false) }
        }
        Button(object.locked ? "Unlock" : "Lock") {
          Easels.update(easel.id) { $0.objects[id: id]?.locked.toggle() }
        }
        Button("Delete") { delete([id]) }
      }
    }
  }

  private func primaryDrag(_ transform: Transform) -> some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        if drag == nil { beginDrag(value, transform: transform) }
        switch drag {
        case .pan(let start):
          updateView { easel in
            easel.originX = start.x - (value.translation.width) / easel.zoom
            easel.originY = start.y - (value.translation.height) / easel.zoom
          }
        case .move(let id, _, let origin):
          let dx = value.translation.width / transform.zoom
          let dy = value.translation.height / transform.zoom
          mutate { easel in
            guard var object = easel.objects[id: id] else { return }
            object.x = origin.origin.x + dx
            object.y = origin.origin.y + dy
            easel.objects[id: id] = object
          }
        case .resize:
          resize(to: value.location, transform: transform)
        case .draw:
          let point = transform.toCanvas(value.location)
          if liveStroke.last.map({ hypot($0.x - point.x, $0.y - point.y) > 1.2 }) ?? true {
            liveStroke.append(StrokePoint(x: point.x, y: point.y))
          }
        case nil:
          break
        }
      }
      .onEnded { _ in endDrag() }
  }

  private func beginDrag(_ value: DragGesture.Value, transform: Transform) {
    if spaceHold.isDown || tool == .select && hit(value.startLocation, transform: transform) == nil {
      snapshot()
      drag = .pan(start: CGPoint(x: current.originX, y: current.originY))
      return
    }
    if tool == .draw {
      snapshot()
      let point = transform.toCanvas(value.startLocation)
      liveStroke = [StrokePoint(x: point.x, y: point.y)]
      drag = .draw
      return
    }
    if tool == .select, let id = hit(value.startLocation, transform: transform) {
      snapshot()
      selection = id
      current.objects[id: id].map { drag = .move(id: id, start: value.startLocation, origin: $0.frame) }
      mutate { $0.bringToFront(id) }
    }
  }

  private func endDrag() {
    if case .draw = drag, liveStroke.count > 1 {
      let stroke = Stroke(points: liveStroke, color: strokeColor, width: strokeWidth)
      mutate { $0.add(.stroke(stroke: stroke)) }
    }
    liveStroke = []
    drag = nil
  }

  private func tap(_ location: CGPoint, transform: Transform) {
    editingText = nil
    if tool == .text {
      addText(at: transform.toCanvas(location))
      tool = .select
      return
    }
    if tool == .link {
      addLink(at: transform.toCanvas(location))
      tool = .select
      return
    }
    if tool == .select {
      selection = hit(location, transform: transform)
    }
  }

  private func hit(_ location: CGPoint, transform: Transform) -> CanvasObject.ID? {
    let canvas = transform.toCanvas(location)
    for object in current.objects.reversed() {
      if object.kind == .stroke {
        if let stroke = object.stroke, Self.hits(stroke, point: canvas) { return object.id }
      } else if object.frame.insetBy(dx: -4, dy: -4).contains(canvas) {
        return object.id
      }
    }
    return nil
  }

  private func resize(to location: CGPoint, transform: Transform) {
    guard case let .resize(id, corner, _, origin) = drag else { return }
    let canvas = transform.toCanvas(location)
    var x = origin.minX, y = origin.minY, w = origin.width, h = origin.height
    switch corner {
    case .topLeft: w = origin.maxX - canvas.x; h = origin.maxY - canvas.y; x = canvas.x; y = canvas.y
    case .topRight: w = canvas.x - origin.minX; h = origin.maxY - canvas.y; y = canvas.y
    case .bottomLeft: w = origin.maxX - canvas.x; h = canvas.y - origin.minY; x = canvas.x
    case .bottomRight: w = canvas.x - origin.minX; h = canvas.y - origin.minY
    }
    mutate { $0.resize(id, x: x, y: y, width: w, height: h) }
  }

  private func addText(at point: CGPoint?) {
    snapshot()
    let origin = point ?? CGPoint(x: current.originX - 120, y: current.originY - 60)
    let object = CanvasObject.text(at: origin)
    mutate { $0.add(object) }
    selection = object.id
    editingText = object.id
  }

  private func addLink(at point: CGPoint?) {
    guard let window = NSApp.keyWindow else { return }
    let tab = space.selectedTab
    presentModal(over: window) { dismiss in
      AddLinkDialog(
        address: tab?.url.absoluteString ?? "", title: tab?.displayTitle ?? "",
        save: { url, title in
          snapshot()
          let origin = point ?? CGPoint(x: current.originX - 130, y: current.originY - 36)
          let object = CanvasObject.link(at: origin, url: url, title: title.isEmpty ? url.host() ?? url.absoluteString : title)
          mutate { $0.add(object) }
          selection = object.id
        }, dismiss: dismiss)
    }
  }

  private func pickImages() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK else { return }
    addImages(panel.urls.compactMap { NSImage(contentsOf: $0) }, names: panel.urls.map(\.lastPathComponent))
  }

  private func addImages(_ images: [NSImage], names: [String] = [], at point: CGPoint? = nil) {
    guard !images.isEmpty else { return }
    snapshot()
    var origin = point ?? CGPoint(x: current.originX - 140, y: current.originY - 100)
    for (index, image) in images.enumerated() {
      do {
        let mediaID = try Easels.storeImage(image)
        let size = Easels.fittedSize(image)
        let object = CanvasObject.image(at: origin, mediaID: mediaID, size: size)
        var titled = object
        if names.indices.contains(index) { titled.title = names[index] }
        mutate { $0.add(titled) }
        selection = titled.id
        origin.x += 24
        origin.y += 24
      } catch {
        toast(error as? Easels.Failure == .tooLarge ? "Image is too large" : "Couldn't add image")
      }
    }
    tool = .select
  }

  private func capturePage() {
    guard let tab = space.selectedTab else {
      toast("No page to capture")
      return
    }
    Engine.shared.perform(tab.id) { contents in
      contents.snapshot { image in
        guard let image else { return }
        MainActor.assumeIsolated {
          do {
            snapshot()
            let mediaID = try Easels.storeImage(image)
            let size = Easels.fittedSize(image, maxEdge: 360)
            let origin = CGPoint(x: current.originX - size.width / 2, y: current.originY - size.height / 2)
            let object = CanvasObject.capture(
              at: origin, mediaID: mediaID, sourceURL: tab.url, sourceTitle: tab.displayTitle, capturedAt: .now,
              size: size)
            mutate { $0.add(object) }
            selection = object.id
            tool = .select
            SoundEffect.play(.capture)
          } catch {
            toast("Couldn't capture page")
          }
        }
      }
    }
  }

  private func paste(at point: CGPoint?) {
    let pasteboard = NSPasteboard.general
    if let image = NSImage(pasteboard: pasteboard) {
      addImages([image], at: point)
      return
    }
    if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      if let url = URL(string: text), NoteMarkdown.isSafe(url) {
        snapshot()
        let origin = point ?? CGPoint(x: current.originX - 130, y: current.originY - 36)
        let object = CanvasObject.link(at: origin, url: url, title: url.host() ?? text)
        mutate { $0.add(object) }
        selection = object.id
      } else {
        snapshot()
        let origin = point ?? CGPoint(x: current.originX - 120, y: current.originY - 60)
        let object = CanvasObject.text(at: origin, text: text)
        mutate { $0.add(object) }
        selection = object.id
      }
    }
  }

  private func drop(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
    for (index, provider) in providers.enumerated() {
      let origin = CGPoint(x: point.x + CGFloat(index) * 24, y: point.y + CGFloat(index) * 24)
      if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        _ = provider.loadDataRepresentation(for: .image) { data, _ in
          guard let data, let image = NSImage(data: data) else { return }
          Task { @MainActor in addImages([image], at: origin) }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
          let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
          guard let url, let image = NSImage(contentsOf: url) else { return }
          Task { @MainActor in addImages([image], names: [url.lastPathComponent], at: origin) }
        }
      }
    }
    return true
  }

  private func deleteSelected() -> KeyPress.Result {
    if editingText != nil { return .ignored }
    guard let id = selection else { return .ignored }
    delete([id])
    return .handled
  }

  private func delete(_ ids: Set<CanvasObject.ID>) {
    snapshot()
    var media: [UUID] = []
    mutate { easel in
      media = easel.delete(ids).compactMap(\.mediaID)
    }
    media.forEach(Easels.removeMedia)
    selection = nil
    editingText = nil
  }

  private func nudge(_ dx: Double, _ dy: Double) {
    guard let id = selection, editingText == nil else { return }
    snapshot()
    mutate { $0.move(id, by: dx / current.zoom, dy: dy / current.zoom) }
  }

  private func pan(by delta: CGSize) {
    updateView { easel in
      easel.originX -= delta.width / easel.zoom
      easel.originY -= delta.height / easel.zoom
    }
  }

  private func zoom(by factor: CGFloat, around _: CGPoint?) {
    updateView { easel in
      easel.zoom = Easel.clampedZoom(easel.zoom * factor)
    }
  }

  private func resetView() {
    updateView {
      $0.zoom = 1
      $0.originX = 0
      $0.originY = 0
    }
  }

  private func snapshot() {
    undoStack.append(current)
    if undoStack.count > 50 { undoStack.removeFirst() }
    redoStack = []
  }

  private func undo() {
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(current)
    Easels.update(easel.id, touch: false) { $0 = previous }
  }

  private func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(current)
    Easels.update(easel.id, touch: false) { $0 = next }
  }

  private func mutate(touch: Bool = true, _ body: (inout Easel) -> Void) {
    Easels.update(easel.id, touch: touch, body)
  }

  private func updateView(_ body: (inout Easel) -> Void) {
    Easels.update(easel.id, touch: false, body)
  }

  private func textBinding(_ object: CanvasObject) -> Binding<String> {
    Binding(
      get: { easels[id: easel.id]?.objects[id: object.id]?.text ?? object.text },
      set: { text in mutate { $0.objects[id: object.id]?.text = text } })
  }

  private func loadImages() {
    for object in current.objects {
      guard let id = object.mediaID, images[id] == nil else { continue }
      images[id] = Easels.loadImage(id)
    }
  }

  private func drawGrid(_ context: GraphicsContext, transform: Transform, size: CGSize) {
    let step: Double = transform.zoom < 0.5 ? 80 : 40
    let visible = transform.visibleRect
    var x = (visible.minX / step).rounded(.down) * step
    while x < visible.maxX {
      var y = (visible.minY / step).rounded(.down) * step
      while y < visible.maxY {
        let point = transform.toScreen(CGPoint(x: x, y: y))
        context.fill(
          Path(ellipseIn: CGRect(x: point.x - 0.7, y: point.y - 0.7, width: 1.4, height: 1.4)),
          with: .color(Theme.secondaryText.opacity(0.28)))
        y += step
      }
      x += step
    }
  }

  private static func path(_ stroke: Stroke, transform: Transform) -> Path? {
    guard let first = stroke.points.first else { return nil }
    var path = Path()
    path.move(to: transform.toScreen(CGPoint(x: first.x, y: first.y)))
    for point in stroke.points.dropFirst() {
      path.addLine(to: transform.toScreen(CGPoint(x: point.x, y: point.y)))
    }
    return path
  }

  private static func hits(_ stroke: Stroke, point: CGPoint) -> Bool {
    let tolerance = max(stroke.width, 6)
    guard let first = stroke.points.first else { return false }
    var previous = first
    for next in stroke.points.dropFirst() {
      if distance(point, previous, next) <= tolerance { return true }
      previous = next
    }
    return false
  }

  private static func distance(_ point: CGPoint, _ a: StrokePoint, _ b: StrokePoint) -> Double {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = max(dx * dx + dy * dy, 0.0001)
    let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / length, 0), 1)
    return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
  }

  private enum Drag {
    case pan(start: CGPoint)
    case move(id: CanvasObject.ID, start: CGPoint, origin: CGRect)
    case resize(id: CanvasObject.ID, corner: Corner, start: CGPoint, origin: CGRect)
    case draw
  }

  private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in rect: CGRect) -> CGPoint {
      switch self {
      case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
      case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
      case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
      case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
      }
    }
  }

  private struct Transform {
    var origin: CGPoint
    var zoom: Double
    var size: CGSize

    func toCanvas(_ screen: CGPoint) -> CGPoint {
      CGPoint(x: origin.x + (screen.x - size.width / 2) / zoom, y: origin.y + (screen.y - size.height / 2) / zoom)
    }

    func toScreen(_ canvas: CGPoint) -> CGPoint {
      CGPoint(x: (canvas.x - origin.x) * zoom + size.width / 2, y: (canvas.y - origin.y) * zoom + size.height / 2)
    }

    func rect(_ frame: CGRect) -> CGRect {
      let origin = toScreen(frame.origin)
      return CGRect(x: origin.x, y: origin.y, width: frame.width * zoom, height: frame.height * zoom)
    }

    var visibleRect: CGRect {
      let origin = toCanvas(.zero)
      return CGRect(x: origin.x, y: origin.y, width: size.width / zoom, height: size.height / zoom)
    }
  }
}

private struct LinkCard: View {
  let object: CanvasObject
  let profile: UUID
  let open: () -> Void
  @State private var favicon: NSImage?

  var body: some View {
    HStack(spacing: 10) {
      Group {
        if let favicon {
          Image(nsImage: favicon).resizable()
        } else {
          Image(systemName: "link").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.icon)
        }
      }
      .frame(width: 16, height: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(object.title.isEmpty ? (object.url?.host() ?? "Link") : object.title)
          .font(.system(size: 13, weight: .medium)).lineLimit(1)
        if let host = object.url?.host() {
          Text(host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
    .onTapGesture(count: 2, perform: open)
    .task(id: object.url) {
      guard let url = object.url else { return }
      favicon = await Autocomplete.favicon(profile, false, url)
    }
  }
}

private struct MediaCard: View {
  let object: CanvasObject
  let image: NSImage?
  let open: () -> Void

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
      } else {
        VStack(spacing: 6) {
          Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(.secondary)
          Text("Image unavailable").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      if object.kind == .capture {
        HStack(spacing: 6) {
          Image(systemName: "camera").font(.system(size: 10, weight: .medium))
          Text(object.title.isEmpty ? "Capture" : object.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
    .onTapGesture(count: 2) { if object.kind == .capture { open() } }
  }
}

private final class SpaceHold {
  var isDown = false
  private var monitor: Any?

  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      if event.keyCode == 49 { self?.isDown = event.type == .keyDown }
      return event
    }
  }

  func stop() {
    monitor.map(NSEvent.removeMonitor)
    monitor = nil
    isDown = false
  }
}

private struct CanvasEventCatcher: NSViewRepresentable {
  var onScroll: (CGSize) -> Void
  var onMagnify: (CGFloat) -> Void

  func makeNSView(context: Context) -> Catcher {
    let view = Catcher()
    view.onScroll = onScroll
    view.onMagnify = onMagnify
    return view
  }

  func updateNSView(_ view: Catcher, context: Context) {
    view.onScroll = onScroll
    view.onMagnify = onMagnify
  }

  final class Catcher: NSView {
    var onScroll: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
      if event.modifierFlags.contains(.command) {
        onMagnify?(event.scrollingDeltaY > 0 ? 1.06 : 0.94)
      } else {
        onScroll?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
      }
    }

    override func magnify(with event: NSEvent) {
      onMagnify?(1 + event.magnification)
    }
  }
}
