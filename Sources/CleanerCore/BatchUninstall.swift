import Darwin
import Foundation

public struct UninstallSelection: Sendable, Identifiable {
  public var id: String { apps.map(\.id).joined(separator: "|") }
  public let apps: [AppRecord]
  public let files: [RelatedFile]
  public let preservedSharedIDs: [String]
}
public enum BatchUninstall {
  /// Only exact app-specific paths are suggested; a retained copy protects its data.
  public static func review(apps: [AppRecord], installed: [AppRecord]) -> UninstallSelection {
    let selectedIDs = Set(apps.map(\.id))
    let retainedBundleIDs = Set(installed.filter { !selectedIDs.contains($0.id) }.map(\.bundleID))
    let protected = Set(apps.map(\.bundleID)).intersection(retainedBundleIDs)
    let candidates = apps.filter { !protected.contains($0.bundleID) }.flatMap {
      AppScanner.relatedFiles(for: $0)
    }
    let files = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values
      .sorted { $0.url.path < $1.url.path }
    return UninstallSelection(apps: apps, files: files, preservedSharedIDs: protected.sorted())
  }
  public static func moveToTrash(apps: [AppRecord], files: [RelatedFile]) throws -> [URL] {
    try moveToTrash(apps: apps, files: files, beforeMove: nil)
  }
  static func moveToTrash(
    apps: [AppRecord], files: [RelatedFile], beforeMove: ((URL) throws -> Void)?
  ) throws -> [URL] {
    guard !apps.isEmpty, Set(apps.map(\.id)).count == apps.count else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    // Complete preflight before moving anything. Recheck disk ownership, not stale UI state.
    for app in apps { try TrashService.validateApplication(app, at: app.url) }
    let installed = AppScanner.scan(measureSizes: false)
    let fresh = review(apps: apps, installed: installed)
    let allowed = Dictionary(uniqueKeysWithValues: fresh.files.map { ($0.id, $0) })
    guard Set(files.map(\.id)).count == files.count else {
      throw TrashServiceError.staleRelatedFiles(expected: fresh.files, provided: files)
    }
    for file in files {
      guard let current = allowed[file.id], current.url == file.url, file.id == file.url.path else {
        throw TrashServiceError.staleRelatedFiles(expected: fresh.files, provided: files)
      }
      try TrashService.validateCanonicalNonSymlink(file.url)
    }
    let sources = apps.map(\.url) + files.map(\.url)
    let snapshots = try Dictionary(
      uniqueKeysWithValues: sources.map { ($0.path, try identity($0)) })
    var moved: [URL] = []
    // Move ALL executables before any support data. A failure never silently claims success.
    for url in sources {
      do {
        try beforeMove?(url)
        try TrashService.validateCanonicalNonSymlink(url)
        guard try identity(url) == snapshots[url.path] else { throw CocoaError(.fileReadUnknown) }
        if let app = apps.first(where: { $0.url == url }) {
          try TrashService.validateApplication(app, at: url)
        } else {
          // A new retained copy must protect shared data even after executables moved.
          let live = AppScanner.scan(measureSizes: false)
          let stillAllowed = review(apps: apps, installed: live).files
          guard stillAllowed.contains(where: { $0.url == url }) else {
            throw TrashServiceError.staleRelatedFiles(expected: stillAllowed, provided: files)
          }
        }
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        moved.append(result as URL? ?? url)
      } catch {
        throw TrashServiceError.partialFailure(moved: moved, failed: url, underlying: error)
      }
    }
    return moved
  }
  private struct Identity: Equatable {
    let device: UInt64
    let inode: UInt64
    let seconds: Int64
    let nanos: Int64
  }
  private static func identity(_ url: URL) throws -> Identity {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
    return Identity(
      device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
      seconds: Int64(value.st_mtimespec.tv_sec), nanos: Int64(value.st_mtimespec.tv_nsec))
  }

}
