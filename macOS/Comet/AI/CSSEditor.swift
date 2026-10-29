import AppKit
import SwiftUI

// A monospaced CSS editor with line numbers, undo, and lightweight highlighting.
struct CSSEditor: NSViewRepresentable {
  @Binding var text: String
  var onEdit: () -> Void = {}

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> CSSEditorContainer {
    let view = CSSEditorContainer()
    view.textView.delegate = context.coordinator
    view.textView.string = text
    view.relayoutNumbers()
    CSSHighlight.apply(to: view.textView)
    return view
  }

  func updateNSView(_ view: CSSEditorContainer, context: Context) {
    context.coordinator.parent = self
    guard view.textView.string != text else { return }
    let selected = view.textView.selectedRange()
    view.textView.string = text
    CSSHighlight.apply(to: view.textView)
    view.relayoutNumbers()
    let end = (text as NSString).length
    view.textView.setSelectedRange(NSRange(location: min(selected.location, end), length: 0))
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: CSSEditor
    private var isApplying = false

    init(_ parent: CSSEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard !isApplying, let view = notification.object as? NSTextView, let container = view.superview?.superview as? CSSEditorContainer
        ?? view.enclosingScrollView?.superview as? CSSEditorContainer
      else {
        guard !isApplying, let view = notification.object as? NSTextView else { return }
        parent.text = view.string
        parent.onEdit()
        isApplying = true
        CSSHighlight.apply(to: view)
        isApplying = false
        return
      }
      parent.text = view.string
      parent.onEdit()
      isApplying = true
      CSSHighlight.apply(to: view)
      container.relayoutNumbers()
      isApplying = false
    }
  }
}

final class CSSEditorContainer: NSView {
  let gutter = NSTextView()
  let scroll = NSScrollView()
  let textView = NSTextView()
  private var observer: NSObjectProtocol?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
    layer?.cornerRadius = 6

    gutter.isEditable = false
    gutter.isSelectable = false
    gutter.isRichText = false
    gutter.drawsBackground = false
    gutter.backgroundColor = .clear
    gutter.font = Self.font
    gutter.textColor = .secondaryLabelColor
    gutter.alignment = .right
    gutter.textContainerInset = NSSize(width: 4, height: 8)
    addSubview(gutter)

    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    addSubview(scroll)

    textView.isEditable = true
    textView.isRichText = true
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.font = Self.font
    textView.textColor = .labelColor
    textView.insertionPointColor = .labelColor
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.lineFragmentPadding = 0
    textView.setAccessibilityLabel("CSS")
    scroll.documentView = textView
    scroll.contentView.postsBoundsChangedNotifications = true
    observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak self] _ in self?.layoutSubtreeIfNeeded() }
  }

  required init?(coder: NSCoder) { nil }

  static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

  func relayoutNumbers() {
    let count = max(textView.string.components(separatedBy: "\n").count, 1)
    let numbers = (1...count).map(String.init).joined(separator: "\n")
    if gutter.string != numbers { gutter.string = numbers }
    gutter.font = Self.font
    gutter.textColor = .secondaryLabelColor
  }

  override func layout() {
    super.layout()
    let gutterWidth: CGFloat = 40
    let offset = scroll.contentView.bounds.origin.y
    let height = max(textView.frame.height, bounds.height)
    gutter.frame = NSRect(x: 0, y: -offset, width: gutterWidth - 4, height: height)
    scroll.frame = NSRect(x: gutterWidth, y: 0, width: max(bounds.width - gutterWidth, 0), height: bounds.height)
    let width = scroll.contentSize.width
    guard width > 1 else { return }
    let inset = textView.textContainerInset
    textView.textContainer?.containerSize = NSSize(width: max(width - inset.width * 2, 0), height: CGFloat.greatestFiniteMagnitude)
    let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
    let textHeight = max(scroll.contentSize.height, used + inset.height * 2)
    if abs(textView.frame.width - width) > 0.5 || abs(textView.frame.height - textHeight) > 0.5 {
      textView.frame = NSRect(x: 0, y: 0, width: width, height: textHeight)
    }
  }
}

@MainActor
private enum CSSHighlight {
  static func apply(to textView: NSTextView) {
    guard let storage = textView.textStorage else { return }
    let selected = textView.selectedRange()
    let full = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.setAttributes([.font: CSSEditorContainer.font, .foregroundColor: NSColor.labelColor], range: full)
    let string = storage.string as NSString
    var index = 0
    var comment = false
    while index < string.length {
      if comment {
        let end = string.range(of: "*/", range: NSRange(location: index, length: string.length - index))
        let range = NSRange(location: index, length: (end.location == NSNotFound ? string.length : end.location + 2) - index)
        storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: range)
        comment = end.location == NSNotFound
        index = NSMaxRange(range)
        continue
      }
      let ch = string.substring(with: NSRange(location: index, length: 1))
      if ch == "/" && index + 1 < string.length && string.substring(with: NSRange(location: index + 1, length: 1)) == "*" {
        comment = true
        continue
      }
      if ch == "\"" || ch == "'" {
        let end = string.range(of: ch, options: [], range: NSRange(location: index + 1, length: string.length - index - 1))
        let length = end.location == NSNotFound ? string.length - index : end.location - index + 1
        storage.addAttributes([.foregroundColor: NSColor.systemGreen], range: NSRange(location: index, length: length))
        index += length
        continue
      }
      if ch == ":" || ch == "{" || ch == "}" || ch == ";" {
        storage.addAttributes([.foregroundColor: NSColor.systemBlue], range: NSRange(location: index, length: 1))
      }
      index += 1
    }
    storage.endEditing()
    textView.setSelectedRange(selected)
  }
}
