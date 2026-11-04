import Darwin
import Foundation

public enum StartupScope: String, CaseIterable, Sendable {
  case user = "Your Account"
  case allUsers = "All Users"
  case system = "System Services"

  var folder: String {
    switch self {
    case .user: NSHomeDirectory() + "/Library/LaunchAgents"
    case .allUsers: "/Library/LaunchAgents"
    case .system: "/Library/LaunchDaemons"
    }
  }
  /// Agents run inside your login session; daemons run in the system domain and need admin.
  public var needsAdmin: Bool { self == .system }
}

public struct StartupItem: Identifiable, Sendable {
  public var id: String { url.path }
  public let label: String
  public let url: URL
  public let scope: StartupScope
  public let program: String?
  /// App or executable the item launches, e.g. "Docker" for a helper inside Docker.app.
  public let owner: String
  /// Second part of the reverse-DNS label, e.g. "Google" for com.google.keystone.
  public let vendor: String
  public let isEnabled: Bool
  public let launchesAtLogin: Bool
  public let isRunning: Bool
  /// The program it launches no longer exists: usually left behind by an uninstalled app.
  public let programMissing: Bool

  public var startsAtLogin: Bool { isEnabled && launchesAtLogin }
}

public enum StartupItemsError: LocalizedError {
  case invalidLabel(String)
  case notRemovable(String)
  public var errorDescription: String? {
    switch self {
    case .invalidLabel(let label): "Unexpected characters in startup item label: \(label)"
    case .notRemovable(let label):
      "\(label) is installed for all users. Turn it off instead, or remove its app."
    }
  }
}

/// Launch agents and daemons: what starts automatically, whether it runs, and on/off control
/// through launchctl's per-domain enable/disable overrides.
public enum StartupItems {
  public static func scan() -> [StartupItem] {
    let running = runningExecutables()
    let userDisabled = parseDisabled(launchctl(["print-disabled", "gui/\(getuid())"]))
    let systemDisabled = parseDisabled(launchctl(["print-disabled", "system"]))
    return StartupScope.allCases.flatMap { scope -> [StartupItem] in
      let folder = URL(fileURLWithPath: scope.folder, isDirectory: true)
      let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
      return files.filter { $0.pathExtension == "plist" }.compactMap {
        item(at: $0, scope: scope, disabled: scope.needsAdmin ? systemDisabled : userDisabled, running: running)
      }
    }.sorted { $0.owner.localizedStandardCompare($1.owner) == .orderedAscending }
  }

  static func item(
    at url: URL, scope: StartupScope, disabled: [String: Bool], running: Set<String>
  ) -> StartupItem? {
    guard let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let label = plist["Label"] as? String
    else { return nil }
    let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
    let launchesAtLogin =
      (plist["RunAtLoad"] as? Bool) == true || (plist["KeepAlive"] as? Bool) == true
      || plist["KeepAlive"] is [String: Any]
    // A launchctl override (enable/disable) beats the plist's own Disabled key.
    let isEnabled = !(disabled[label] ?? ((plist["Disabled"] as? Bool) ?? false))
    let missing = program.map { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) } ?? false
    return StartupItem(
      label: label, url: url, scope: scope, program: program, owner: owner(of: program, label: label),
      vendor: vendor(of: label), isEnabled: isEnabled, launchesAtLogin: launchesAtLogin,
      isRunning: program.map { running.contains($0) } ?? false, programMissing: missing)
  }

  /// `launchctl print-disabled` lines look like `"com.vendor.item" => disabled`.
  static func parseDisabled(_ output: String) -> [String: Bool] {
    var result: [String: Bool] = [:]
    for line in output.split(separator: "\n") {
      let parts = line.components(separatedBy: "=>")
      guard parts.count == 2 else { continue }
      let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      let state = parts[1].trimmingCharacters(in: .whitespaces)
      guard !label.isEmpty else { continue }
      result[label] = state == "disabled" || state == "true"
    }
    return result
  }

  static func owner(of program: String?, label: String) -> String {
    guard let program else { return label }
    let components = program.split(separator: "/")
    if let app = components.first(where: { $0.hasSuffix(".app") }) {
      return String(app.dropLast(4))
    }
    return components.last.map(String.init) ?? label
  }

  static func vendor(of label: String) -> String {
    let parts = label.split(separator: ".")
    guard parts.count >= 2 else { return label }
    return parts[1].prefix(1).uppercased() + parts[1].dropFirst()
  }

  // MARK: Actions

  /// Turns an item on or off. Agents change only for your account; system services ask for admin.
  public static func setEnabled(_ item: StartupItem, _ enabled: Bool) throws {
    try validate(item.label)
    if item.scope.needsAdmin {
      let path = item.url.path.replacingOccurrences(of: "'", with: "")
      let shell =
        enabled
        ? "/bin/launchctl enable system/\(item.label); /bin/launchctl bootstrap system '\(path)' 2>/dev/null; exit 0"
        : "/bin/launchctl disable system/\(item.label); /bin/launchctl bootout system/\(item.label) 2>/dev/null; exit 0"
      try QuickMemoryCleanup.runAsAdministrator(shell)
      return
    }
    let domain = "gui/\(getuid())"
    _ = try QuickMemoryCleanup.execute("/bin/launchctl", [enabled ? "enable" : "disable", "\(domain)/\(item.label)"])
    // Start or stop it now too; failures here only mean it was already in that state.
    if enabled {
      _ = try? QuickMemoryCleanup.execute("/bin/launchctl", ["bootstrap", domain, item.url.path])
    } else {
      _ = try? QuickMemoryCleanup.execute("/bin/launchctl", ["bootout", "\(domain)/\(item.label)"])
    }
  }

  /// Stops an item in your account and moves its file to Trash.
  public static func remove(_ item: StartupItem) throws -> URL {
    guard item.scope == .user else { throw StartupItemsError.notRemovable(item.label) }
    try validate(item.label)
    _ = try? QuickMemoryCleanup.execute("/bin/launchctl", ["bootout", "gui/\(getuid())/\(item.label)"])
    try TrashService.validateCanonicalNonSymlink(item.url)
    var result: NSURL?
    try FileManager.default.trashItem(at: item.url, resultingItemURL: &result)
    return (result as URL?) ?? item.url
  }

  private static func validate(_ label: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
    guard !label.isEmpty, label.unicodeScalars.allSatisfy(allowed.contains) else {
      throw StartupItemsError.invalidLabel(label)
    }
  }

  private static func runningExecutables() -> Set<String> {
    Set(MemoryMonitor.allProcessIDs().compactMap(MemoryMonitor.executablePath))
  }

  private static func launchctl(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}
