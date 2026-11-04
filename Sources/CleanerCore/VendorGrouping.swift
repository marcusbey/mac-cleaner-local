import Foundation

public struct VendorGroup: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let apps: [AppRecord]
  public var bytes: Int64 {
    let related = Dictionary(
      apps.map { ($0.bundleID.isEmpty ? $0.id : $0.bundleID, $0.relatedBytes) },
      uniquingKeysWith: max)
    return apps.reduce(0) { $0 + $1.bytes } + related.values.reduce(0, +)
  }
  public var sizeIncomplete: Bool { apps.contains(where: { $0.sizeIncomplete }) }
  public var isGroup: Bool { apps.count > 1 }
}

/// Organization is a display convention, not proof that shared data can be removed.
public enum VendorGrouping {
  private static let names = [
    "com.adobe": "Adobe", "com.microsoft": "Microsoft", "com.apple": "Apple",
    "com.google": "Google", "com.autodesk": "Autodesk", "com.nektony": "Nektony",
    "com.jetbrains": "JetBrains", "com.elgato": "Elgato", "com.logitech": "Logitech",
    "com.fiplab": "FIPLAB", "com.electron": "Electron",
  ]
  private static let generic: Set<String> = [
    "com.electron", "org.electron", "com.github", "io.github", "net.sourceforge", "org.python",
    "com.example", "org.example", "local.appcleaner",
  ]
  public static func groups(
    for apps: [AppRecord], query: String = "", largestFirst: Bool = false, enabled: Bool = true
  ) -> [VendorGroup] {
    let unique = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      .values
    let buckets = Dictionary(grouping: unique) { app in
      enabled ? namespace(app.bundleID) ?? app.id : app.id
    }
    return buckets.compactMap { key, values -> VendorGroup? in
      let members = values.sorted {
        if largestFirst, $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      let title =
        members.count > 1
        ? names[key] ?? key.split(separator: ".").last.map { String($0).capitalized } ?? key
        : members[0].name
      let match =
        query.isEmpty || title.localizedCaseInsensitiveContains(query)
        || members.contains {
          $0.name.localizedCaseInsensitiveContains(query)
            || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
      guard match else { return nil }
      // Keep full group membership visible when a member matches, so its total never lies.
      return VendorGroup(id: key, name: title, apps: members)
    }.sorted {
      if largestFirst, $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }
  public static func namespace(_ identifier: String) -> String? {
    let parts = identifier.lowercased().split(separator: ".")
    guard parts.count >= 3,
      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } })
    else { return nil }
    let key = parts.prefix(2).joined(separator: ".")
    guard !generic.contains(key) else { return nil }
    return key
  }
}

public struct ApplicationSizeSection: Identifiable, Sendable {
  public let id: String
  public let title: String
  public let groups: [VendorGroup]
}
public enum ApplicationHierarchy {
  public static func sections(groups: [VendorGroup], bySize: Bool) -> [ApplicationSizeSection] {
    guard bySize else {
      return [ApplicationSizeSection(id: "all", title: "Applications", groups: groups)]
    }
    let ranges: [(String, String, Int64, Int64)] = [
      ("large", "More than 1 GB", 1_000_000_000, Int64.max),
      ("medium", "100 MB – 1 GB", 100_000_000, 1_000_000_000),
      ("small", "10 MB – 100 MB", 10_000_000, 100_000_000),
      ("tiny", "Less than 10 MB", 0, 10_000_000),
    ]
    return ranges.compactMap { id, title, minimum, maximum in
      let matches = groups.filter { $0.bytes >= minimum && $0.bytes < maximum }
      return matches.isEmpty ? nil : ApplicationSizeSection(id: id, title: title, groups: matches)
    }
  }
}
