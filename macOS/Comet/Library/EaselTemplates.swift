import Foundation

enum EaselTemplates {
  static func research(page: URL, title: String) -> [CanvasObject] {
    let pageCard = CanvasObject.link(at: CGPoint(x: 80, y: 80), url: page, title: title)
    let notes = CanvasObject.text(at: CGPoint(x: 420, y: 80), text: "What matters on this page?")
    var link = CanvasObject(
      id: UUID(), kind: .connector, x: 0, y: 0, width: 1, height: 1, fromID: pageCard.id, toID: notes.id,
      relation: "related to")
    link.relation = "related to"
    return [pageCard, notes, link]
  }

  static func comparison() -> [CanvasObject] {
    let left = CanvasObject.text(at: CGPoint(x: 40, y: 80), text: "# Option A")
    let right = CanvasObject.text(at: CGPoint(x: 400, y: 80), text: "# Option B")
    let decision = CanvasObject.text(at: CGPoint(x: 220, y: 280), text: "Decision")
    let toLeft = CanvasObject(
      id: UUID(), kind: .connector, x: 0, y: 0, width: 1, height: 1, fromID: left.id, toID: decision.id, relation: "supports")
    let toRight = CanvasObject(
      id: UUID(), kind: .connector, x: 0, y: 0, width: 1, height: 1, fromID: right.id, toID: decision.id, relation: "contradicts")
    return [left, right, decision, toLeft, toRight]
  }

  static func named(_ name: String) -> [CanvasObject] {
    switch name {
    case "Website research":
      return research(page: URL(string: "https://example.com")!, title: "Page")
    case "Comparison":
      return comparison()
    case "Brainstorm":
      return [
        CanvasObject.text(at: CGPoint(x: 80, y: 40), text: "# Idea"),
        CanvasObject.text(at: CGPoint(x: 360, y: 40), text: "Note"),
        CanvasObject.text(at: CGPoint(x: 80, y: 220), text: "- [ ] Next step"),
      ]
    default:
      return []
    }
  }
}
