import Foundation

public struct AutoCleanPolicy: Sendable {
  public var threshold: Double
  public var cooldown: TimeInterval
  private var aboveSince: Date?
  private var lastAttempt: Date?
  public init(threshold: Double = 85, cooldown: TimeInterval = 900) {
    self.threshold = min(95, max(60, threshold))
    self.cooldown = cooldown
  }
  public mutating func reset() { aboveSince = nil }
  public mutating func recordAttempt(at date: Date) {
    lastAttempt = date
    aboveSince = nil
  }
  public mutating func shouldAttempt(percent: Double, enabled: Bool, now: Date) -> Bool {
    guard enabled, percent.isFinite else {
      aboveSince = nil
      return false
    }
    guard percent >= threshold else {
      aboveSince = nil
      return false
    }
    if aboveSince == nil { aboveSince = now }
    guard now.timeIntervalSince(aboveSince!) >= 30 else { return false }
    guard lastAttempt.map({ now.timeIntervalSince($0) >= cooldown }) ?? true else { return false }
    recordAttempt(at: now)
    return true
  }
}

public struct QuickCleanResult: Sendable {
  public let beforeFree: UInt64
  public let afterFree: UInt64
  public let ran: Bool
  public let message: String
}

public enum QuickMemoryCleanupError: LocalizedError {
  case cancelled
  case failed(Int32)
  public var errorDescription: String? {
    switch self {
    case .cancelled: "Administrator authorization was cancelled."
    case .failed(let status): "The system purge command failed (status \(status))."
    }
  }
}

/// Runs macOS `/usr/sbin/purge`, which flushes the file cache (inactive/speculative/purgeable pages)
/// so it shows up as free RAM. It never quits apps. It needs root: either a one-time sudoers rule
/// limited to that exact binary (password-free, required for Auto mode) or an admin prompt per run.
public enum QuickMemoryCleanup {
  static let purge = "/usr/sbin/purge"
  static let sudoersFile = "/etc/sudoers.d/app-cleaner-purge"

  /// True when `sudo -n /usr/sbin/purge` would run without asking for a password.
  public static func canPurgeSilently() -> Bool {
    (try? execute("/usr/bin/sudo", ["-n", "-l", purge])) == 0
  }

  /// - Parameter interactive: when password-free purge is not set up, ask for an admin password.
  ///   Auto mode passes `false` so it never pops a prompt in the background.
  public static func run(interactive: Bool) throws -> QuickCleanResult {
    let before = try MemoryMonitor.snapshot(includeApplications: false)
    if canPurgeSilently() {
      let status = try execute("/usr/bin/sudo", ["-n", purge])
      guard status == 0 else { throw QuickMemoryCleanupError.failed(status) }
    } else if interactive {
      try runAsAdministrator(purge)
    } else {
      return QuickCleanResult(
        beforeFree: before.breakdown.freeBytes, afterFree: before.breakdown.freeBytes, ran: false,
        message: "Auto clean skipped: enable password-free cleaning first.")
    }
    let after = try MemoryMonitor.snapshot(includeApplications: false)
    return QuickCleanResult(
      beforeFree: before.breakdown.freeBytes, afterFree: after.breakdown.freeBytes, ran: true,
      message: "Memory cache flushed.")
  }

  /// One-time admin prompt that installs a sudoers rule allowing only `/usr/sbin/purge`, no arguments.
  public static func enableSilentPurge(user: String = NSUserName()) throws {
    let script = try sudoersInstallScript(user: user)
    try runAsAdministrator(script)
  }

  public static func disableSilentPurge() throws {
    try runAsAdministrator("/bin/rm -f \(sudoersFile)")
  }

  static func sudoersInstallScript(user: String) throws -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard !user.isEmpty, user.unicodeScalars.allSatisfy(allowed.contains) else {
      throw QuickMemoryCleanupError.failed(-1)
    }
    // visudo validates the rule before it is installed, so a bad file can never lock out sudo.
    return
      "t=$(/usr/bin/mktemp) && printf '%s ALL=(root) NOPASSWD: \(purge)\\n' '\(user)' > \"$t\""
      + " && /usr/sbin/visudo -cf \"$t\" && /usr/bin/install -m 0440 -o root -g wheel \"$t\" \(sudoersFile);"
      + " s=$?; /bin/rm -f \"$t\"; exit $s"
  }

  static func appleScriptLiteral(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      + "\""
  }

  private static func runAsAdministrator(_ shell: String) throws {
    let source = "do shell script \(appleScriptLiteral(shell)) with administrator privileges"
    let status = try execute("/usr/bin/osascript", ["-e", source])
    // osascript exits 1 for both cancel (-128) and failures; treat as cancel only when nothing ran.
    guard status == 0 else { throw status == 1 ? QuickMemoryCleanupError.cancelled : .failed(status) }
  }

  @discardableResult private static func execute(_ path: String, _ arguments: [String]) throws
    -> Int32
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}
