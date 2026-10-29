import CommonCrypto
import CryptoKit
import Foundation

struct SyncRecord: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var type: String
  var revision: Int
  var replica: String
  var deleted: Bool
  var checksum: String
  var payload: Data
}

struct SyncConflict: Equatable, Identifiable, Sendable {
  var id: UUID { entity }
  var entity: UUID
  var local: SyncRecord
  var remote: SyncRecord
}

struct SyncMergeResult: Equatable, Sendable {
  var records: [SyncRecord]
  var conflicts: [SyncConflict]
}

enum SyncMerge {
  // Same replica: the higher revision wins, including a deletion. Different replicas with different bytes conflict
  // and the local record stays until someone chooses.
  static func merge(local: [SyncRecord], remote: [SyncRecord]) -> SyncMergeResult {
    var records = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
    var conflicts: [SyncConflict] = []
    for incoming in remote {
      guard let current = records[incoming.id] else {
        records[incoming.id] = incoming
        continue
      }
      if current.checksum == incoming.checksum && current.deleted == incoming.deleted {
        records[incoming.id] = current.revision >= incoming.revision ? current : incoming
        continue
      }
      if current.replica == incoming.replica {
        records[incoming.id] = current.revision >= incoming.revision ? current : incoming
        continue
      }
      conflicts.append(SyncConflict(entity: incoming.id, local: current, remote: incoming))
    }
    return SyncMergeResult(records: Array(records.values), conflicts: conflicts)
  }
}

enum SyncChecksum {
  static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

enum SyncCrypto {
  enum Failure: Error { case short, decrypt }

  static func seal(_ data: Data, passphrase: String) throws -> Data {
    let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let box = try AES.GCM.seal(data, using: key(passphrase, salt: salt))
    guard let combined = box.combined else { throw Failure.decrypt }
    return salt + combined
  }

  static func open(_ data: Data, passphrase: String) throws -> Data {
    guard data.count > 16 else { throw Failure.short }
    let salt = data.prefix(16)
    let box = try AES.GCM.SealedBox(combined: data.dropFirst(16))
    return try AES.GCM.open(box, using: key(passphrase, salt: salt))
  }

  private static func key(_ passphrase: String, salt: Data) -> SymmetricKey {
    var derived = Data(count: 32)
    let password = Array(passphrase.utf8)
    _ = derived.withUnsafeMutableBytes { derivedBytes in
      salt.withUnsafeBytes { saltBytes in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2),
          password, password.count,
          saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
          80_000,
          derivedBytes.bindMemory(to: UInt8.self).baseAddress, 32)
      }
    }
    return SymmetricKey(data: derived)
  }
}

enum FolderSync {
  static let fileName = "CometSync.json"

  static func write(_ records: [SyncRecord], to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(records)
    let destination = directory.appending(path: fileName)
    let temporary = directory.appending(path: fileName + ".tmp")
    try data.write(to: temporary, options: .atomic)
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
  }

  static func read(from directory: URL) throws -> [SyncRecord] {
    let url = directory.appending(path: fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([SyncRecord].self, from: Data(contentsOf: url))
  }
}

enum WebDAVSync {
  static func request(_ url: URL, method: String, user: String, password: String, body: Data?) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    let token = Data("\(user):\(password)".utf8).base64EncodedString()
    request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    request.timeoutInterval = 20
    return request
  }

  static func allows(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" || EndpointPolicy.isLoopback(url)
  }
}

struct SyncState: Codable, Equatable, Sendable {
  var replica: String = UUID().uuidString
  var revisions: [String: Int] = [:]
  var checksums: [String: String] = [:]
}

enum SyncSnapshot {
  static func records(notes: [Note], easels: [Easel], state: inout SyncState) -> [SyncRecord] {
    notes.map { record(id: $0.id, type: "note", payload: (try? JSONEncoder().encode($0)) ?? Data(), state: &state) }
      + easels.map { record(id: $0.id, type: "easel", payload: (try? JSONEncoder().encode($0)) ?? Data(), state: &state) }
  }

  private static func record(id: UUID, type: String, payload: Data, state: inout SyncState) -> SyncRecord {
    let checksum = SyncChecksum.hex(payload)
    let key = id.uuidString
    var revision = state.revisions[key] ?? 0
    if state.checksums[key] != checksum {
      revision += 1
      state.revisions[key] = revision
      state.checksums[key] = checksum
    }
    return SyncRecord(
      id: id, type: type, revision: revision, replica: state.replica, deleted: false, checksum: checksum, payload: payload)
  }
}
