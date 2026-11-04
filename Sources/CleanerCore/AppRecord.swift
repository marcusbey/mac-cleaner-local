import Foundation

public struct AppRecord: Identifiable, Sendable, Hashable {
  public let id: String
  public let name: String
  public let bundleID: String
  public let url: URL
  public let version: String
  public let modified: Date?
  public let bytes: Int64
  public let relatedBytes: Int64
  public let sizeIncomplete: Bool
  public var totalBytes: Int64 { bytes + relatedBytes }

  public init(
    id: String,
    name: String,
    bundleID: String,
    url: URL,
    version: String,
    modified: Date?,
    bytes: Int64,
    relatedBytes: Int64 = 0,
    sizeIncomplete: Bool = false
  ) {
    self.id = id
    self.name = name
    self.bundleID = bundleID
    self.url = url
    self.version = version
    self.modified = modified
    self.bytes = bytes
    self.relatedBytes = relatedBytes
    self.sizeIncomplete = sizeIncomplete
  }
}

public struct RelatedFile: Identifiable, Sendable, Hashable {
  public let id: String
  public let url: URL
  public let category: String
  public let bytes: Int64

  public init(id: String, url: URL, category: String, bytes: Int64) {
    self.id = id
    self.url = url
    self.category = category
    self.bytes = bytes
  }
}
