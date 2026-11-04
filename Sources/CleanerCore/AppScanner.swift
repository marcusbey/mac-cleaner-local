import Foundation

public enum AppScanner {
  public static func scan(
    roots: [URL] = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true),
      URL(
        fileURLWithPath: "/Library/Application Support/Adobe/Adobe Desktop Common",
        isDirectory: true),
      URL(
        fileURLWithPath: "/Library/Application Support/Adobe/Creative Cloud Libraries",
        isDirectory: true),
      URL(
        fileURLWithPath: "/Library/Application Support/Adobe/Adobe OS Extension", isDirectory: true),
      URL(fileURLWithPath: "/Library/Application Support/Microsoft/MAU2.0", isDirectory: true),
    ],
    includeRelatedSizes: Bool = false,
    measureSizes: Bool = true
  ) -> [AppRecord] {
    let fileManager = FileManager.default
    var records: [AppRecord] = []

    for root in roots {
      scanDirectory(
        root.standardizedFileURL, fileManager: fileManager, records: &records,
        measureSizes: measureSizes)
    }

    if includeRelatedSizes && measureSizes {
      records = records.map { app in
        let related = relatedFiles(for: app)
        return AppRecord(
          id: app.id, name: app.name, bundleID: app.bundleID, url: app.url, version: app.version,
          modified: app.modified, bytes: app.bytes,
          relatedBytes: related.reduce(0) { $0 + max(0, $1.bytes) },
          sizeIncomplete: related.contains { $0.bytes < 0 })
      }
    }
    return records.sorted {
      $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
    }
  }

  public static func relatedFiles(
    for app: AppRecord,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [RelatedFile] {
    guard isSafeBundleIdentifier(app.bundleID) else { return [] }

    let library = home.standardizedFileURL.appendingPathComponent("Library", isDirectory: true)
    let candidates: [(category: String, url: URL)] = [
      ("Caches", library.appendingPathComponent("Caches/\(app.bundleID)")),
      ("Preferences", library.appendingPathComponent("Preferences/\(app.bundleID).plist")),
      (
        "Application Support", library.appendingPathComponent("Application Support/\(app.bundleID)")
      ),
      (
        "Saved Application State",
        library.appendingPathComponent("Saved Application State/\(app.bundleID).savedState")
      ),
      ("Logs", library.appendingPathComponent("Logs/\(app.bundleID)")),
      (
        "Application Scripts", library.appendingPathComponent("Application Scripts/\(app.bundleID)")
      ),
      ("Container", library.appendingPathComponent("Containers/\(app.bundleID)")),
    ]

    return candidates.compactMap { candidate in
      let url = candidate.url.standardizedFileURL
      guard isExistingNonSymlink(url) else { return nil }
      return RelatedFile(
        id: url.path,
        url: url,
        category: candidate.category,
        bytes: candidate.category == "Container"
          ? BoundedStorage.containerBytes(url) : directorySize(url)
      )
    }
  }

  public static func directorySize(_ url: URL) -> Int64 {
    let fileManager = FileManager.default
    let resourceKeys: Set<URLResourceKey> = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    let standardizedURL = url.standardizedFileURL

    guard let rootValues = try? standardizedURL.resourceValues(forKeys: resourceKeys),
      rootValues.isSymbolicLink != true
    else {
      return 0
    }

    if rootValues.isRegularFile == true {
      return Int64(rootValues.fileSize ?? 0)
    }

    guard rootValues.isDirectory == true,
      let enumerator = fileManager.enumerator(
        at: standardizedURL,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [],
        errorHandler: { _, _ in true }
      )
    else {
      return 0
    }

    var total: Int64 = 0
    while let item = enumerator.nextObject() as? URL {
      guard let values = try? item.resourceValues(forKeys: resourceKeys) else { continue }
      if values.isSymbolicLink == true {
        if values.isDirectory == true {
          enumerator.skipDescendants()
        }
        continue
      }
      if values.isRegularFile == true {
        total += Int64(values.fileSize ?? 0)
      }
    }
    return total
  }

  private static func scanDirectory(
    _ directory: URL,
    fileManager: FileManager,
    records: inout [AppRecord],
    measureSizes: Bool
  ) {
    guard isExistingNonSymlink(directory),
      (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
      let children = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ],
        options: []
      )
    else {
      return
    }

    for child in children {
      guard
        let values = try? child.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        ), values.isSymbolicLink != true, values.isDirectory == true
      else {
        continue
      }

      if child.pathExtension.lowercased() == "app" {
        records.append(
          makeRecord(
            for: child.standardizedFileURL, modified: values.contentModificationDate,
            measureSizes: measureSizes))
      } else if !["framework", "bundle", "xpc", "appex"].contains(child.pathExtension.lowercased())
      {
        scanDirectory(
          child, fileManager: fileManager, records: &records, measureSizes: measureSizes)
      }
    }
  }

  private static func makeRecord(for appURL: URL, modified: Date?, measureSizes: Bool) -> AppRecord
  {
    let metadata = bundleMetadata(at: appURL)
    let fallbackName = appURL.deletingPathExtension().lastPathComponent
    return AppRecord(
      id: appURL.path,
      name: metadata.name.flatMap {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
      } ?? fallbackName,
      bundleID: metadata.bundleID ?? "",
      url: appURL,
      version: metadata.version ?? "",
      modified: modified,
      bytes: measureSizes ? directorySize(appURL) : 0
    )
  }

  static func bundleIdentifier(at appURL: URL) -> String? {
    bundleMetadata(at: appURL).bundleID
  }

  private static func bundleMetadata(at appURL: URL) -> (
    bundleID: String?, name: String?, version: String?
  ) {
    let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
      let dictionary = plist as? [String: Any]
    else {
      return (nil, nil, nil)
    }

    let bundleID = dictionary["CFBundleIdentifier"] as? String
    let name =
      (dictionary["CFBundleDisplayName"] as? String)
      ?? (dictionary["CFBundleName"] as? String)
    let version =
      (dictionary["CFBundleShortVersionString"] as? String)
      ?? (dictionary["CFBundleVersion"] as? String)
    return (bundleID, name, version)
  }

  private static func isExistingNonSymlink(_ url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path),
      let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
    else {
      return false
    }
    return values.isSymbolicLink != true
      && url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func isSafeBundleIdentifier(_ bundleID: String) -> Bool {
    !bundleID.isEmpty
      && bundleID != "."
      && bundleID != ".."
      && !bundleID.contains("/")
      && !bundleID.contains(Character("\\"))
  }
}
