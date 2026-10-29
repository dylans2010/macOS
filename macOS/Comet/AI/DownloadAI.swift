import Foundation
import UniformTypeIdentifiers

enum DownloadAI {
  static func request(name: String, site: String?, title: String?, mime: String?) -> AIRequest {
    AIRequest.make(
      feature: .tidyDownloads,
      system: AIGuard.defaultSystem + """
         Propose a clearer filename for a finished download. Reply with only the filename, including its original extension. \
        Use the given metadata. Do not invent document contents. Do not add a path.
        """,
      prompt: [
        "Filename: \(name)",
        site.map { "Site: \($0)" },
        title.map { "Title: \($0)" },
        mime.map { "Type: \($0)" },
      ].compactMap { $0 }.joined(separator: "\n"),
      provenance: "download:\(site ?? "file")",
      cacheKey: "download:\(name)|\(site ?? "")|\(title ?? "")",
      maxTokens: 40,
      timeout: .seconds(12))
  }

  // Keeps the original extension, strips path components and reserved characters, and refuses an empty result.
  static func sanitize(_ proposed: String, original: String) -> String? {
    var name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = (name as NSString).pathComponents
    if components.contains(where: { $0 == ".." || $0 == "~" }) { return nil }
    name = (name as NSString).lastPathComponent
    if name == ".." || name == "." || name.isEmpty { return nil }
    let originalExt = (original as NSString).pathExtension
    var ext = (name as NSString).pathExtension
    var stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    if !originalExt.isEmpty, ext.lowercased() != originalExt.lowercased() {
      stem = name
      ext = originalExt
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_()[]{}'"))
    let cleaned =
      stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce(into: "") { $0.append($1) }
      .replacingOccurrences(of: "--", with: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
    guard !cleaned.isEmpty, !cleaned.contains("..") else { return nil }
    let filename = ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
    guard filename != original, filename.count <= 180 else { return filename == original ? nil : String(filename.prefix(180)) }
    return filename
  }
}
