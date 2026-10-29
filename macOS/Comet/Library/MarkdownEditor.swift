import AppKit
import SwiftUI

// A system text view that stores Markdown and styles headings, lists, quotes, code and links as they are typed.
struct MarkdownEditor: NSViewRepresentable {
  @Binding var text: String
  var isEditable = true
  var onChange: () -> Void = {}

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    let textView = EditorTextView()
    textView.delegate = context.coordinator
    textView.string = text
    textView.isEditable = isEditable
    textView.isRichText = true
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = true
    textView.font = EditorTextView.body
    textView.textColor = .labelColor
    textView.insertionPointColor = .labelColor
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 18, height: 12)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0
    textView.setAccessibilityLabel("Note")
    scroll.documentView = textView
    MarkdownHighlight.apply(to: textView)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scroll.documentView as? EditorTextView else { return }
    textView.isEditable = isEditable
    guard textView.string != text else { return }
    let selected = textView.selectedRange()
    textView.string = text
    MarkdownHighlight.apply(to: textView)
    let end = (text as NSString).length
    textView.setSelectedRange(NSRange(location: min(selected.location, end), length: min(selected.length, max(end - selected.location, 0))))
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MarkdownEditor
    private var isApplying = false

    init(_ parent: MarkdownEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard !isApplying, let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
      parent.onChange()
      isApplying = true
      MarkdownHighlight.apply(to: textView)
      isApplying = false
    }
  }
}

private final class EditorTextView: NSTextView {
  static let body = NSFont.systemFont(ofSize: 15)
  static let heading1 = NSFont.systemFont(ofSize: 26, weight: .semibold)
  static let heading2 = NSFont.systemFont(ofSize: 21, weight: .semibold)
  static let heading3 = NSFont.systemFont(ofSize: 17, weight: .semibold)
  static let code = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  static let quote = NSFont.systemFont(ofSize: 15, weight: .regular).item(italic: true) ?? NSFont.systemFont(ofSize: 15)

  override var acceptsFirstResponder: Bool { isEditable }
}

@MainActor
private enum MarkdownHighlight {
  static func apply(to textView: NSTextView) {
    guard let storage = textView.textStorage else { return }
    let full = NSRange(location: 0, length: storage.length)
    let selected = textView.selectedRange()
    storage.beginEditing()
    storage.setAttributes(
      [
        .font: EditorTextView.body,
        .foregroundColor: NSColor.labelColor,
        .backgroundColor: NSColor.clear,
      ], range: full)
    let string = storage.string as NSString
    var inFence = false
    var location = 0
    while location < string.length {
      let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
      let line = string.substring(with: lineRange)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("```") {
        inFence.toggle()
        storage.addAttributes(codeAttributes, range: lineRange)
      } else if inFence {
        storage.addAttributes(codeAttributes, range: lineRange)
      } else {
        styleBlock(line, range: lineRange, in: storage)
        styleInline(string, range: lineRange, in: storage)
      }
      location = NSMaxRange(lineRange)
    }
    storage.endEditing()
    textView.setSelectedRange(selected)
  }

  private static var codeAttributes: [NSAttributedString.Key: Any] {
    [.font: EditorTextView.code, .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor]
  }

  private static func styleBlock(_ line: String, range: NSRange, in storage: NSTextStorage) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("####") {
      storage.addAttributes([.font: EditorTextView.heading3, .foregroundColor: NSColor.labelColor], range: range)
      dimMarkers(in: range, prefix: trimmed.prefix { $0 == "#" }.count, storage: storage)
    } else if trimmed.hasPrefix("###") {
      storage.addAttributes([.font: EditorTextView.heading3], range: range)
      dimMarkers(in: range, prefix: 3, storage: storage)
    } else if trimmed.hasPrefix("##") {
      storage.addAttributes([.font: EditorTextView.heading2], range: range)
      dimMarkers(in: range, prefix: 2, storage: storage)
    } else if trimmed.hasPrefix("#") {
      storage.addAttributes([.font: EditorTextView.heading1], range: range)
      dimMarkers(in: range, prefix: 1, storage: storage)
    } else if trimmed.hasPrefix(">") {
      storage.addAttributes(
        [.font: EditorTextView.quote, .foregroundColor: NSColor.secondaryLabelColor], range: range)
    } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
      dimMarkers(in: range, prefix: 1, storage: storage)
    }
  }

  private static func dimMarkers(in range: NSRange, prefix: Int, storage: NSTextStorage) {
    let string = storage.string as NSString
    let line = string.substring(with: range)
    guard let start = line.firstIndex(where: { $0 == "#" || $0 == "-" || $0 == "*" || $0 == "+" || $0 == ">" })
    else { return }
    let offset = line.distance(from: line.startIndex, to: start)
    let length = min(prefix, (line as NSString).length - offset)
    guard length > 0 else { return }
    storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: NSRange(location: range.location + offset, length: length))
  }

  private static func styleInline(_ string: NSString, range: NSRange, in storage: NSTextStorage) {
    apply(#"\*\*[^*]+\*\*|__[^_]+__"#, in: string, range: range, storage: storage) { _ in
      [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]
    }
    apply(#"`[^`]+`"#, in: string, range: range, storage: storage) { _ in codeAttributes }
    apply(#"\[[^\]]+\]\([^)]+\)"#, in: string, range: range, storage: storage) { _ in
      [.foregroundColor: NSColor.controlAccentColor]
    }
  }

  private static func apply(
    _ pattern: String, in string: NSString, range: NSRange, storage: NSTextStorage,
    attributes: (NSRange) -> [NSAttributedString.Key: Any]
  ) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    for match in regex.matches(in: string as String, range: range) {
      storage.addAttributes(attributes(match.range), range: match.range)
    }
  }
}

extension NSFont {
  fileprivate func item(italic: Bool) -> NSFont? {
    var traits = fontDescriptor.symbolicTraits
    if italic { traits.insert(.italic) }
    return NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize)
  }
}
