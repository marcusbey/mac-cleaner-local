import AppKit
import Darwin
import Foundation

public enum DiskCleanupCategory: String, CaseIterable, Sendable {
  case cache = "Caches"
  case logs = "Logs"
  case largeDownload = "Large Downloads"
  case developer = "Developer"
  case dependencies = "Dependencies"
}

public struct DiskCleanupRoot: Sendable, Hashable {
  public let category: DiskCleanupCategory
  public let url: URL

  public init(category: DiskCleanupCategory, url: URL) {
    self.category = category
    self.url = url.standardizedFileURL
  }
}

struct DiskFileSnapshot: Sendable, Hashable {
  let device: UInt64
  let inode: UInt64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let size: Int64

  static func capture(_ url: URL) throws -> DiskFileSnapshot {
    var information = stat()
    guard lstat(url.path, &information) == 0 else { throw CocoaError(.fileReadUnknown) }
    return DiskFileSnapshot(
      device: UInt64(information.st_dev),
      inode: UInt64(information.st_ino),
      modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec),
      size: Int64(information.st_size)
    )
  }
}

public struct DiskCleanupCandidate: Identifiable, Sendable, Hashable {
  public let id: String
  public let url: URL
  public let category: DiskCleanupCategory
  public let bytes: Int64
  public let modified: Date?
  public let reason: String
  public let ownerBundleID: String?
  public let scopeRoot: URL
  /// Spotlight's last-opened date (kMDItemLastUsedDate); nil when never opened or not indexed.
  public let lastOpened: Date?
  public let selectedByDefault = false
  let snapshot: DiskFileSnapshot?

  public init(
    url: URL,
    category: DiskCleanupCategory,
    bytes: Int64,
    modified: Date?,
    reason: String,
    ownerBundleID: String?,
    scopeRoot: URL,
    lastOpened: Date? = nil
  ) {
    let standardized = url.standardizedFileURL
    self.id = standardized.path
    self.url = standardized
    self.category = category
    self.bytes = bytes
    self.modified = modified
    self.reason = reason
    self.ownerBundleID = ownerBundleID
    self.scopeRoot = scopeRoot.standardizedFileURL
    self.lastOpened = lastOpened
    self.snapshot = try? DiskFileSnapshot.capture(standardized)
  }

  init(
    url: URL,
    category: DiskCleanupCategory,
    bytes: Int64,
    modified: Date?,
    reason: String,
    ownerBundleID: String?,
    scopeRoot: URL,
    snapshot: DiskFileSnapshot,
    lastOpened: Date? = nil
  ) {
    let standardized = url.standardizedFileURL
    self.id = standardized.path
    self.url = standardized
    self.category = category
    self.bytes = bytes
    self.modified = modified
    self.reason = reason
    self.ownerBundleID = ownerBundleID
    self.scopeRoot = scopeRoot.standardizedFileURL
    self.lastOpened = lastOpened
    self.snapshot = snapshot
  }
}

public struct DiskScanIssue: Identifiable, Sendable, Hashable {
  public let id: String
  public let path: String
  public let message: String
}

public struct DiskScanResult: Sendable {
  public let candidates: [DiskCleanupCandidate]
  public let errors: [DiskScanIssue]
  public let truncated: Bool
  public let cancelled: Bool
}

public struct DiskVolumeUsage: Sendable, Equatable {
  public let totalBytes: Int64
  public let availableBytes: Int64
  public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

  public static func read(for url: URL = FileManager.default.homeDirectoryForCurrentUser) throws
    -> DiskVolumeUsage
  {
    let values = try url.resourceValues(forKeys: [
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
    ])
    guard let total = values.volumeTotalCapacity else { throw CocoaError(.fileReadUnknown) }
    let available =
      values.volumeAvailableCapacityForImportantUsage
      ?? values.volumeAvailableCapacity.map(Int64.init)
      ?? 0
    return DiskVolumeUsage(
      totalBytes: Int64(total), availableBytes: min(Int64(total), max(0, available)))
  }
}

public enum DiskCleanupScanner {
  public static func defaultJunkRoots(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [DiskCleanupRoot] {
    let library = home.standardizedFileURL.appendingPathComponent("Library", isDirectory: true)
    return [
      DiskCleanupRoot(
        category: .cache, url: library.appendingPathComponent("Caches", isDirectory: true)),
      DiskCleanupRoot(
        category: .logs, url: library.appendingPathComponent("Logs", isDirectory: true)),
    ]
  }

  public static func scanJunk(
    roots: [DiskCleanupRoot] = defaultJunkRoots(),
    runningBundleIDs: Set<String> = Set(
      NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
    limit: Int = 2_000,
    sizeEntryLimit: Int = 50_000,
    sizeTimeLimit: TimeInterval = 2,
    shouldCancel: () -> Bool = { Task.isCancelled }
  ) -> DiskScanResult {
    var candidates: [DiskCleanupCandidate] = []
    var issues: [DiskScanIssue] = []
    var truncated = false
    var cancelled = false
    let fileManager = FileManager.default

    scanLoop: for root in roots {
      if shouldCancel() {
        cancelled = true
        break
      }
      let rootURL = root.url.standardizedFileURL
      guard isCanonicalDirectory(rootURL) else {
        issues.append(
          issue(rootURL, "Folder is missing, unreadable, or not a canonical directory."))
        continue
      }
      let children: [URL]
      do {
        children = try fileManager.contentsOfDirectory(
          at: rootURL,
          includingPropertiesForKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey,
          ],
          options: [.skipsHiddenFiles]
        )
      } catch {
        issues.append(issue(rootURL, error.localizedDescription))
        continue
      }

      for child in children.sorted(by: { $0.path < $1.path }) {
        if shouldCancel() {
          cancelled = true
          break scanLoop
        }
        if candidates.count >= max(0, limit) {
          truncated = true
          break scanLoop
        }
        let url = child.standardizedFileURL
        guard isDirectCanonicalChild(url, of: rootURL),
          let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey,
          ]),
          values.isSymbolicLink != true,
          values.isDirectory == true || values.isRegularFile == true
        else { continue }

        let owner = likelyBundleIdentifier(url.lastPathComponent)
        if let owner, isProtected(owner, runningBundleIDs: runningBundleIDs) { continue }
        if owner?.hasPrefix("com.apple.") == true { continue }
        guard let snapshot = try? DiskFileSnapshot.capture(url) else { continue }
        switch boundedSize(
          of: url, entryLimit: sizeEntryLimit, timeLimit: sizeTimeLimit,
          shouldCancel: shouldCancel)
        {
        case .cancelled:
          cancelled = true
          break scanLoop
        case .truncated(let message):
          truncated = true
          issues.append(issue(url, message))
        case .complete(let bytes):
          candidates.append(
            DiskCleanupCandidate(
              url: url,
              category: root.category,
              bytes: bytes,
              modified: values.contentModificationDate,
              reason: owner.map { "Cache or log data named for \($0). Review it before removal." }
                ?? "Review carefully: the folder name does not identify one application.",
              ownerBundleID: owner,
              scopeRoot: rootURL,
              snapshot: snapshot
            ))
        }
      }
    }
    return DiskScanResult(
      candidates: candidates.sorted {
        $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes
      },
      errors: issues,
      truncated: truncated,
      cancelled: cancelled
    )
  }

  public static func scanLargeFiles(
    folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Downloads"),
    minimumBytes: Int64 = 100_000_000,
    limit: Int = 2_000,
    shouldCancel: () -> Bool = { Task.isCancelled }
  ) -> DiskScanResult {
    let root = folder.standardizedFileURL
    guard isCanonicalDirectory(root) else {
      return DiskScanResult(
        candidates: [], errors: [issue(root, "Folder is missing, unreadable, or not canonical.")],
        truncated: false, cancelled: false)
    }
    var candidates: [DiskCleanupCandidate] = []
    var errors: [DiskScanIssue] = []
    var truncated = false
    var cancelled = false
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
      .fileSizeKey, .contentModificationDateKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { url, error in
          errors.append(issue(url, error.localizedDescription))
          return true
        })
    else {
      return DiskScanResult(
        candidates: [], errors: [issue(root, "Could not enumerate folder.")], truncated: false,
        cancelled: false)
    }
    while let url = enumerator.nextObject() as? URL {
      if shouldCancel() {
        cancelled = true
        break
      }
      if candidates.count >= max(0, limit) {
        truncated = true
        break
      }
      guard isCanonicalDescendant(url.standardizedFileURL, of: root),
        let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isSymbolicLink != true
      else {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true,
        Int64(values.fileSize ?? 0) >= minimumBytes,
        let snapshot = try? DiskFileSnapshot.capture(url)
      else { continue }
      candidates.append(
        DiskCleanupCandidate(
          url: url,
          category: .largeDownload,
          bytes: Int64(values.fileSize ?? 0),
          modified: values.contentModificationDate,
          reason: "Large user file. Confirm that you no longer need it before moving it to Trash.",
          ownerBundleID: nil,
          scopeRoot: root,
          snapshot: snapshot,
          lastOpened: DiskCleanupSafety.lastOpened(url)
        ))
    }
    return DiskScanResult(
      candidates: candidates.sorted {
        $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes
      },
      errors: errors, truncated: truncated, cancelled: cancelled)
  }

  static func isProtected(_ identifier: String, runningBundleIDs: Set<String>) -> Bool {
    runningBundleIDs.contains(identifier)
      || runningBundleIDs.contains {
        identifier.hasPrefix($0 + ".") || $0.hasPrefix(identifier + ".")
      }
  }

  static func likelyBundleIdentifier(_ name: String) -> String? {
    // These aliases are protective exclusions, not deletion ownership proof.
    let protectiveAliases = ["BraveSoftware":"com.brave", "Codex":"com.openai.codex", "Google":"com.google", "Microsoft":"com.microsoft", "Adobe":"com.adobe", "Claude":"com.anthropic.claudefordesktop"]
    if let identifier = protectiveAliases[name] { return identifier }
    var value = name
    for suffix in [".savedState", ".plist"] where value.hasSuffix(suffix) {
      value.removeLast(suffix.count)
    }
    let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count >= 3,
      pieces.allSatisfy({ part in
        !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
      })
    else { return nil }
    return value
  }

  private static func isCanonicalDirectory(_ url: URL) -> Bool {
    guard url.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private static func isDirectCanonicalChild(_ url: URL, of root: URL) -> Bool {
    url.deletingLastPathComponent().path == root.path
      && url.path.hasPrefix(root.path + "/")
      && url.path == url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func isCanonicalDescendant(_ url: URL, of root: URL) -> Bool {
    url.path.hasPrefix(root.path + "/")
      && url.path == url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func issue(_ url: URL, _ message: String) -> DiskScanIssue {
    DiskScanIssue(id: url.path, path: url.path, message: message)
  }

  private enum SizeMeasurement {
    case complete(Int64)
    case truncated(String)
    case cancelled
  }

  private static func boundedSize(
    of url: URL,
    entryLimit: Int,
    timeLimit: TimeInterval,
    shouldCancel: () -> Bool
  ) -> SizeMeasurement {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    guard let root = try? url.resourceValues(forKeys: keys), root.isSymbolicLink != true else {
      return .complete(0)
    }
    if root.isRegularFile == true { return .complete(Int64(root.fileSize ?? 0)) }
    guard root.isDirectory == true,
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: Array(keys),
        options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
    else { return .complete(0) }
    let deadline = Date().addingTimeInterval(max(0, timeLimit))
    var total: Int64 = 0
    var examined = 0
    while let child = enumerator.nextObject() as? URL {
      if shouldCancel() { return .cancelled }
      if Date() >= deadline { return .truncated("Folder measurement timed out and was skipped.") }
      examined += 1
      if examined > max(0, entryLimit) {
        return .truncated("Folder contains too many entries to measure safely and was skipped.")
      }
      guard let values = try? child.resourceValues(forKeys: keys) else { continue }
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
    }
    return .complete(total)
  }
}

public enum DiskCleanupTrashError: Error, LocalizedError {
  case invalidSelection(URL)
  case changedCandidate(URL)
  case runningOwner(URL)

  public var errorDescription: String? {
    switch self {
    case .invalidSelection(let url): "The item is outside the approved cleanup folders: \(url.path)"
    case .changedCandidate(let url):
      "The item changed after scanning and was not moved: \(url.path)"
    case .runningOwner(let url):
      "Quit the application that owns this item before moving it: \(url.path)"
    }
  }
}

public struct DiskCleanupSkip: Sendable {
  public let url: URL
  public let reason: String
}

public struct DiskCleanupTrashOutcome: Sendable {
  public let moved: [URL]
  public let skipped: [DiskCleanupSkip]
}

public enum DiskCleanupTrashService {
  /// Moves each valid candidate independently, so one stale or in-use item does not block the rest.
  /// Throws only for a malformed request (duplicates) or when nothing at all could be moved.
  public static func moveToTrash(
    _ candidates: [DiskCleanupCandidate],
    allowedRoots: [URL],
    runningBundleIDs: Set<String> = Set(
      NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
  ) throws -> DiskCleanupTrashOutcome {
    guard Set(candidates.map(\.id)).count == candidates.count else {
      throw DiskCleanupTrashError.invalidSelection(
        candidates.first?.url ?? URL(fileURLWithPath: "/"))
    }
    let roots = allowedRoots.map(\.standardizedFileURL)
    var moved: [URL] = []
    var skipped: [(DiskCleanupSkip, Error)] = []
    for candidate in candidates {
      do {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
          .union(runningBundleIDs)
        try validate(candidate, roots: roots, runningBundleIDs: running)
        var result: NSURL?
        try FileManager.default.trashItem(at: candidate.url, resultingItemURL: &result)
        moved.append((result as URL?) ?? candidate.url)
      } catch {
        skipped.append((DiskCleanupSkip(url: candidate.url, reason: error.localizedDescription), error))
      }
    }
    if moved.isEmpty, let first = skipped.first { throw first.1 }
    return DiskCleanupTrashOutcome(moved: moved, skipped: skipped.map(\.0))
  }

  private static func validate(
    _ candidate: DiskCleanupCandidate, roots: [URL], runningBundleIDs: Set<String>
  ) throws {
    guard candidate.url.isFileURL,
      candidate.id == candidate.url.path,
      candidate.url.path == candidate.url.standardizedFileURL.path,
      candidate.scopeRoot == candidate.scopeRoot.standardizedFileURL,
      roots.contains(candidate.scopeRoot),
      isInside(candidate.url, root: candidate.scopeRoot),
      categoryMatchesScope(candidate),
      let snapshot = candidate.snapshot
    else {
      throw DiskCleanupTrashError.invalidSelection(candidate.url)
    }
    let derivedOwner = DiskCleanupScanner.likelyBundleIdentifier(candidate.url.lastPathComponent)
    if derivedOwner?.hasPrefix("com.apple.") == true || derivedOwner == Bundle.main.bundleIdentifier {
      throw DiskCleanupTrashError.invalidSelection(candidate.url)
    }
    if let owner = derivedOwner,
      DiskCleanupScanner.isProtected(owner, runningBundleIDs: runningBundleIDs)
    {
      throw DiskCleanupTrashError.runningOwner(candidate.url)
    }
    try TrashService.validateCanonicalNonSymlink(candidate.url)
    let current = try DiskFileSnapshot.capture(candidate.url)
    // Cache/log folders are written to constantly; same device+inode proves it is the same folder.
    // Downloads are user documents, so any content change since the scan blocks removal.
    let unchanged =
      candidate.category == .largeDownload
      ? current == snapshot
      : current.device == snapshot.device && current.inode == snapshot.inode
    guard unchanged else { throw DiskCleanupTrashError.changedCandidate(candidate.url) }
  }

  private static func isInside(_ url: URL, root: URL) -> Bool {
    url.path.hasPrefix(root.path + "/")
      && url.path == url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func categoryMatchesScope(_ candidate: DiskCleanupCandidate) -> Bool {
    switch candidate.category {
    case .cache:
      return candidate.scopeRoot.lastPathComponent == "Caches"
        && candidate.url.deletingLastPathComponent() == candidate.scopeRoot
    case .logs:
      return candidate.scopeRoot.lastPathComponent == "Logs"
        && candidate.url.deletingLastPathComponent() == candidate.scopeRoot
    case .largeDownload:
      return !hasPackageAncestor(candidate.url, below: candidate.scopeRoot)
    case .developer:
      return candidate.url.deletingLastPathComponent() == candidate.scopeRoot
        && DeveloperCleanupScanner.location(for: candidate) != nil
    case .dependencies:
      return candidate.url.lastPathComponent == "node_modules"
        && !hasPackageAncestor(candidate.url, below: candidate.scopeRoot)
    }
  }

  private static func hasPackageAncestor(_ url: URL, below root: URL) -> Bool {
    var current = url.deletingLastPathComponent()
    while current.path != root.path, current.path.hasPrefix(root.path + "/") {
      if (try? current.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return true }
      current.deleteLastPathComponent()
    }
    return false
  }
}
