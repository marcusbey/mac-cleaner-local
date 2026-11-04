import CoreServices
import Foundation

/// Plain-language verdict on whether a Disk Cleanup item can go to Trash.
public struct DiskCleanupSafety: Sendable, Equatable {
  public enum Level: Int, Sendable, Comparable {
    case safe, likelySafe, review
    public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  public let level: Level
  public let note: String

  /// Cache folders that hold downloaded toolchains/packages: safe, but cost a re-download.
  static let redownloadCaches: Set<String> = [
    "ms-playwright", "homebrew", "cocoapods", "pip", "pypoetry", "go-build", "cypress", "yarn",
    "pnpm", "node-gyp", "electron", "electron-builder", "typescript", "jetbrains", "gradle",
    "bazel", "huggingface", "torch", "uv", "deno", "bun", "puppeteer", "selenium", "sentry",
  ]
  static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
  static let day: TimeInterval = 86_400

  public static func assess(
    _ candidate: DiskCleanupCandidate, now: Date = Date(), installedApps: Set<String> = []
  ) -> Self {
    let age = candidate.modified.map { now.timeIntervalSince($0) / day }
    switch candidate.category {
    case .cache:
      if redownloadCaches.contains(candidate.url.lastPathComponent.lowercased()) {
        return Self(
          level: .likelySafe,
          note: "Downloaded tools or packages. Safe to remove; they download again when next needed.")
      }
      return Self(
        level: .safe,
        note: "Temporary cache. The app rebuilds it automatically; it may start a little slower once.")
    case .logs:
      if let age, age < 1 {
        return Self(
          level: .likelySafe,
          note: "Log written in the last day. Safe unless you are troubleshooting this app right now.")
      }
      return Self(level: .safe, note: "Old diagnostic log. Only used for troubleshooting.")
    case .largeDownload:
      let usage = openedNote(candidate.lastOpened, now: now)
      if installerExtensions.contains(candidate.url.pathExtension.lowercased()) {
        let key = installerKey(candidate.url.lastPathComponent)
        if matchesInstalled(installerKey: key, installed: installedApps) {
          return Self(
            level: .likelySafe,
            note: "Installer for an app that is already installed. You can download it again if needed. \(usage)")
        }
        return Self(
          level: .review,
          note: "Installer whose app is not installed in Applications. You may still need it. \(usage)")
      }
      return Self(
        level: .review,
        note: "Your own file. Remove only if you no longer need it or have a copy elsewhere. \(usage)")
    }
  }

  static func openedNote(_ date: Date?, now: Date) -> String {
    guard let date else { return "No record of it being opened since download." }
    let days = Int(now.timeIntervalSince(date) / day)
    if days >= 365 {
      return "Not opened in over a year (last \(date.formatted(date: .abbreviated, time: .omitted)))."
    }
    return days < 1 ? "Opened today." : "Opened \(days) day\(days == 1 ? "" : "s") ago."
  }

  /// Spotlight's last-opened date, which Finder and apps record when a file is opened.
  public static func lastOpened(_ url: URL) -> Date? {
    guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
    return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
  }

  // MARK: Installer ↔ installed app matching

  /// Version, architecture and packaging words that installer file names add to the app name.
  static let installerNoise: Set<String> = [
    "arm", "aarch", "amd", "intel", "universal", "darwin", "mac", "osx", "apple", "silicon",
    "setup", "installer", "latest", "release", "stable", "beta", "dmg", "pkg", "x",
  ]

  public static func appKey(_ name: String) -> String {
    name.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }
      .map(String.init).joined()
  }

  public static func installerKey(_ fileName: String) -> String {
    let stem = (fileName as NSString).deletingPathExtension.lowercased()
    return stem.components(separatedBy: CharacterSet.letters.inverted)
      .filter { $0.count > 1 && !installerNoise.contains($0) }
      .joined()
  }

  /// Exact match, or an installed app name (4+ letters) that starts the installer name.
  public static func matchesInstalled(installerKey key: String, installed: Set<String>) -> Bool {
    guard !key.isEmpty else { return false }
    return installed.contains(key) || installed.contains { $0.count >= 4 && key.hasPrefix($0) }
  }

  /// Name keys of apps in /Applications and ~/Applications, including one level of subfolders.
  public static func installedAppKeys() -> Set<String> {
    let fileManager = FileManager.default
    let roots = [
      URL(fileURLWithPath: "/Applications"),
      fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]
    var keys = Set<String>()
    for root in roots {
      for item in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
        if item.pathExtension == "app" {
          keys.insert(appKey(item.deletingPathExtension().lastPathComponent))
        } else {
          for nested in (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
          where nested.pathExtension == "app" {
            keys.insert(appKey(nested.deletingPathExtension().lastPathComponent))
          }
        }
      }
    }
    keys.remove("")
    return keys
  }
}

