import XCTest

@testable import Comet

final class ProductivityTests: XCTestCase {
  func testNoteLinksAndBrokenTargets() {
    let a = Note(id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!, title: "Alpha", content: "See [[Beta]]", createdAt: .now)
    let b = Note(id: UUID(), title: "Beta", content: "See [[Alpha]]", createdAt: .now)
    XCTAssertEqual(NoteLinks.targets(in: a.content, notes: [a, b]).map(\.title), ["Beta"])
    XCTAssertEqual(NoteLinks.backlinks(to: a, notes: [a, b]).map(\.id), [b.id])
    XCTAssertEqual(NoteLinks.broken(in: "[[Missing]]", notes: [a]), ["Missing"])
  }

  func testTrashAndPinFilters() {
    let note = Note(id: UUID(), title: "A", content: "", createdAt: .now)
    var library = NotesLibrary()
    library.meta[note.id.uuidString] = NoteMeta(pinned: true, trashedAt: .now)
    XCTAssertTrue(NotesOrganization.visible([note], library: library, filter: .trash).contains { $0.id == note.id })
    XCTAssertTrue(NotesOrganization.visible([note], library: library, filter: .all).isEmpty)
  }

  func testChecklistStaysAttachedToItsNote() {
    let note = Note(id: UUID(), title: "Tasks", content: "- [ ] Write\n- [x] Read", createdAt: .now)
    let tasks = NotesOrganization.tasks(in: [note])
    XCTAssertEqual(tasks.map(\.line), ["Write", "Read"])
    XCTAssertEqual(tasks.map(\.note.id), [note.id, note.id])
    XCTAssertEqual(tasks.map(\.done), [false, true])
  }

  func testClipDoesNotReplaceExistingWriting() {
    let url = URL(string: "https://example.com/a")!
    let appended = NoteClip.append("Quoted", source: url, to: "My notes")
    XCTAssertTrue(appended.hasPrefix("My notes"))
    XCTAssertTrue(appended.contains("https://example.com/a"))
    XCTAssertTrue(NoteClip.page(title: "Page", url: url, excerpt: "Hi").contains("## Excerpt"))
  }

  func testWordCount() {
    let stats = NoteStats.counts("one two three")
    XCTAssertEqual(stats.words, 3)
    XCTAssertGreaterThan(stats.characters, 0)
  }

  func testSyncKeepsBothSidesOfAConflict() {
    let id = UUID()
    let local = SyncRecord(id: id, type: "note", revision: 2, replica: "a", deleted: false, checksum: "one", payload: Data("local".utf8))
    let remote = SyncRecord(id: id, type: "note", revision: 2, replica: "b", deleted: false, checksum: "two", payload: Data("remote".utf8))
    let merged = SyncMerge.merge(local: [local], remote: [remote])
    XCTAssertEqual(merged.conflicts.count, 1)
    XCTAssertEqual(merged.records.first?.checksum, "one")
  }

  func testSyncIsIdempotentWhenBytesMatch() {
    let id = UUID()
    let record = SyncRecord(id: id, type: "note", revision: 3, replica: "a", deleted: false, checksum: "same", payload: Data())
    let once = SyncMerge.merge(local: [record], remote: [record])
    let twice = SyncMerge.merge(local: once.records, remote: [record])
    XCTAssertTrue(once.conflicts.isEmpty)
    XCTAssertTrue(twice.conflicts.isEmpty)
    XCTAssertEqual(twice.records.count, 1)
  }

  func testSameReplicaUsesTheHigherRevisionIncludingDeletion() {
    let id = UUID()
    let older = SyncRecord(id: id, type: "note", revision: 1, replica: "a", deleted: false, checksum: "old", payload: Data())
    let newer = SyncRecord(id: id, type: "note", revision: 4, replica: "a", deleted: true, checksum: "gone", payload: Data())
    let merged = SyncMerge.merge(local: [older], remote: [newer])
    XCTAssertTrue(merged.conflicts.isEmpty)
    XCTAssertEqual(merged.records.first?.deleted, true)
  }

  func testSealedSyncRoundTrip() throws {
    let original = Data("notes".utf8)
    let sealed = try SyncCrypto.seal(original, passphrase: "correct horse")
    XCTAssertNotEqual(sealed, original)
    XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("notes"))
    let opened = try SyncCrypto.open(sealed, passphrase: "correct horse")
    XCTAssertEqual(opened, original)
    XCTAssertThrowsError(try SyncCrypto.open(sealed, passphrase: "wrong"))
  }

  func testConnectorStaysValidAndLockedObjectsDoNotMove() {
    let a = CanvasObject.text(id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!, at: .zero, text: "A")
    let b = CanvasObject.text(id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!, at: CGPoint(x: 100, y: 0), text: "B")
    let connector = CanvasObject(
      id: UUID(), kind: .connector, x: 0, y: 0, width: 1, height: 1, fromID: a.id, toID: b.id, relation: "supports")
    XCTAssertTrue(connector.isValid)
    var easel = Easel(id: UUID(), createdAt: .now, objects: [a, b, connector])
    easel.objects[id: a.id]?.locked = true
    easel.move(a.id, by: 10, dy: 10)
    XCTAssertEqual(easel.objects[id: a.id]?.x, 0)
    XCTAssertEqual(EaselTemplates.comparison().filter { $0.kind == .connector }.count, 2)
  }

  func testTabLayoutDoesNotChangeTabIdentity() {
    XCTAssertEqual(TabLayoutMode(rawValue: "horizontal"), .horizontal)
    XCTAssertEqual(TabLayoutMode(rawValue: "vertical"), .vertical)
    XCTAssertNil(TabLayoutMode(rawValue: "missing"))
  }

  func testPrivacyPresetsOnlyToggleTheRealBlocker() {
    XCTAssertEqual(PrivacyPreset.balanced.enablesBlocker, true)
    XCTAssertEqual(PrivacyPreset.strict.enablesBlocker, true)
    XCTAssertEqual(PrivacyPreset.off.enablesBlocker, false)
    XCTAssertNil(PrivacyPreset.custom.enablesBlocker)
  }

  func testSearchAliasBuildsARealURL() {
    let aliases = [SearchAlias(id: UUID(), keyword: "wiki", template: "https://en.wikipedia.org/wiki/%s")]
    XCTAssertEqual(
      SearchAliases.destination(for: "wiki swift language", aliases: aliases)?.absoluteString,
      "https://en.wikipedia.org/wiki/swift%20language")
    XCTAssertNil(SearchAliases.destination(for: "wiki", aliases: aliases))
    XCTAssertNil(SearchAliases.destination(for: "other cats", aliases: aliases))
  }

  func testSensitiveTextRedactsSecrets() {
    let redacted = SensitiveText.redact("token sk-abcdefghijklmnopqrstuvwxyz and password: hunter2")
    XCTAssertFalse(redacted.contains("sk-abcdefghijklmnopqrstuvwxyz"))
    XCTAssertFalse(redacted.contains("hunter2"))
    XCTAssertTrue(redacted.contains("[redacted]"))
  }

  func testBackupChecksumRejectsTampering() throws {
    let backup = BrowserBackup(notes: [], easels: [], productivity: ProductivityLibrary())
    var data = try BackupPackage.encode(backup)
    data.append(contentsOf: [1, 2, 3])
    XCTAssertThrowsError(try BackupPackage.decode(data))
    let clean = try BackupPackage.encode(backup)
    XCTAssertEqual(try BackupPackage.decode(clean).notes.count, 0)
  }

  func testHibernationSkipsPinnedAudibleAndSplitTabs() {
    XCTAssertTrue(Hibernation.allowed(live: true, unpinned: true, audible: false, loading: false, split: false))
    XCTAssertFalse(Hibernation.allowed(live: true, unpinned: false, audible: false, loading: false, split: false))
    XCTAssertFalse(Hibernation.allowed(live: true, unpinned: true, audible: true, loading: false, split: false))
    XCTAssertFalse(Hibernation.allowed(live: true, unpinned: true, audible: false, loading: false, split: true))
    XCTAssertFalse(Hibernation.allowed(live: false, unpinned: true, audible: false, loading: false, split: false))
  }

  func testWebDAVRejectsPlainHTTPOffThisMac() {
    XCTAssertTrue(WebDAVSync.allows(URL(string: "https://example.com/CometSync.json")!))
    XCTAssertFalse(WebDAVSync.allows(URL(string: "http://example.com/CometSync.json")!))
    XCTAssertTrue(WebDAVSync.allows(URL(string: "http://127.0.0.1:8080/CometSync.json")!))
  }
}
