import Foundation

/// Developer tool data that rebuilds or re-downloads: Xcode build data, package-manager caches,
/// and per-project dependency folders.
public enum DeveloperCleanupScanner {
  struct Location {
    /// Path relative to the home folder.
    let path: String
    /// true: each item inside is offered separately. false: the folder itself is one item.
    let children: Bool
    let level: DiskCleanupSafety.Level
    let note: String
  }

  static let rebuilds = "Rebuilt automatically the next time you build."
  static let redownloads = "package download cache. Re-downloaded when a project next needs it."

  static let locations: [Location] = [
    Location(
      path: "Library/Developer/Xcode/DerivedData", children: true, level: .safe,
      note: "Xcode build products and indexes. \(rebuilds)"),
    Location(
      path: "Library/Developer/Xcode/iOS DeviceSupport", children: true, level: .likelySafe,
      note: "Debug symbols for one iOS version. Copied again when a device on that version connects."),
    Location(
      path: "Library/Developer/Xcode/watchOS DeviceSupport", children: true, level: .likelySafe,
      note: "Debug symbols for one watchOS version. Copied again when that watch connects."),
    Location(
      path: "Library/Developer/CoreSimulator/Caches", children: true, level: .safe,
      note: "iOS Simulator caches. \(rebuilds)"),
    Location(
      path: "Library/Developer/Xcode/Archives", children: true, level: .review,
      note: "App archives you built. Keep the ones you need for crash reports or re-submission."),
    Location(path: ".npm/_cacache", children: false, level: .likelySafe, note: "npm \(redownloads)"),
    Location(path: ".pnpm-store", children: false, level: .likelySafe, note: "pnpm \(redownloads)"),
    Location(
      path: "Library/pnpm/store", children: false, level: .likelySafe, note: "pnpm \(redownloads)"),
    Location(path: ".yarn/berry/cache", children: false, level: .likelySafe, note: "Yarn \(redownloads)"),
    Location(path: ".bun/install/cache", children: false, level: .likelySafe, note: "Bun \(redownloads)"),
    Location(path: ".gradle/caches", children: false, level: .likelySafe, note: "Gradle \(redownloads)"),
    Location(path: ".cargo/registry", children: false, level: .likelySafe, note: "Cargo \(redownloads)"),
    Location(path: "go/pkg/mod", children: false, level: .likelySafe, note: "Go module \(redownloads)"),
    Location(
      path: ".cache", children: true, level: .likelySafe,
      note: "Tool cache (pip, Hugging Face, and others). Re-created or re-downloaded when needed."),
    Location(
      path: "Library/iTunes/iPhone Software Updates", children: true, level: .safe,
      note: "Old iPhone/iPad system update files. Downloaded again if ever needed."),
    Location(
      path: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", children: true,
      level: .safe, note: "Copies of attachments you opened in Mail. The originals stay in your mail."),
  ]

  public static func scan(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    shouldCancel: () -> Bool = { Task.isCancelled }
  ) -> DiskScanResult {
    let home = home.standardizedFileURL
    var candidates: [DiskCleanupCandidate] = []
    var errors: [DiskScanIssue] = []
    for location in locations {
      if shouldCancel() { return result(candidates, errors, cancelled: true) }
      let folder = home.appendingPathComponent(location.path, isDirectory: true)
      guard isPlainDirectory(folder) else { continue }
      let items: [URL]
      if location.children {
        do {
          items = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
          errors.append(DiskScanIssue(id: folder.path, path: folder.path, message: error.localizedDescription))
          continue
        }
      } else {
        items = [folder]
      }
      for item in items where isPlainDirectory(item) || isPlainFile(item) {
        if let candidate = candidate(item.standardizedFileURL, category: .developer, reason: location.note, shouldCancel: shouldCancel) {
          candidates.append(candidate)
        }
      }
    }
    return result(candidates, errors, cancelled: false)
  }

  /// Finds `node_modules` folders under `folder`, never descending into one or into hidden folders.
  public static func scanDependencies(
    in folder: URL, limit: Int = 500, shouldCancel: () -> Bool = { Task.isCancelled }
  ) -> DiskScanResult {
    let root = folder.standardizedFileURL
    var candidates: [DiskCleanupCandidate] = []
    var errors: [DiskScanIssue] = []
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { url, error in
          errors.append(DiskScanIssue(id: url.path, path: url.path, message: error.localizedDescription))
          return true
        })
    else { return result([], errors, cancelled: false) }
    while let url = enumerator.nextObject() as? URL {
      if shouldCancel() { return result(candidates, errors, cancelled: true) }
      guard isPlainDirectory(url) else { continue }
      guard url.lastPathComponent == "node_modules" else { continue }
      enumerator.skipDescendants()
      if let candidate = candidate(url.standardizedFileURL, category: .dependencies, reason: "", scopeRoot: root, shouldCancel: shouldCancel) {
        candidates.append(candidate)
      }
      if candidates.count >= limit { break }
    }
    return result(candidates, errors, cancelled: false, truncated: candidates.count >= limit)
  }

  /// The rule a developer candidate came from, matched by its location below the home folder.
  static func location(for candidate: DiskCleanupCandidate) -> Location? {
    let path = candidate.url.path
    let parent = candidate.url.deletingLastPathComponent().path
    return locations.first {
      $0.children ? parent.hasSuffix("/" + $0.path) : path.hasSuffix("/" + $0.path)
    }
  }

  private static func candidate(
    _ url: URL, category: DiskCleanupCategory, reason: String, scopeRoot: URL? = nil,
    shouldCancel: () -> Bool
  ) -> DiskCleanupCandidate? {
    guard let snapshot = try? DiskFileSnapshot.capture(url) else { return nil }
    let bytes: Int64
    if isPlainFile(url) {
      let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
      bytes = Int64(values?.totalFileAllocatedSize ?? 0)
    } else {
      let tree = SizeTree.scan(url, minimumShare: 1, maxChildren: 0, shouldCancel: shouldCancel)
      guard !tree.cancelled else { return nil }
      bytes = tree.root.bytes
    }
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
    return DiskCleanupCandidate(
      url: url, category: category, bytes: bytes, modified: modified, reason: reason,
      ownerBundleID: nil, scopeRoot: scopeRoot ?? url.deletingLastPathComponent(),
      snapshot: snapshot)
  }

  private static func result(
    _ candidates: [DiskCleanupCandidate], _ errors: [DiskScanIssue], cancelled: Bool,
    truncated: Bool = false
  ) -> DiskScanResult {
    DiskScanResult(
      candidates: candidates.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes },
      errors: errors, truncated: truncated, cancelled: cancelled)
  }

  private static func isPlainDirectory(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    return values?.isDirectory == true && values?.isSymbolicLink != true
  }

  private static func isPlainFile(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    return values?.isRegularFile == true && values?.isSymbolicLink != true
  }
}
