import Foundation

/// A per-user launch agent that starts the app at login with `--background`, so it runs in the
/// menu bar only (no window, no Dock icon). It is only written to disk, never bootstrapped now,
/// so installing it does not start a second copy of the running app.
public struct LoginAgent: Sendable {
  public static let backgroundArgument = "--background"
  public static let standard = LoginAgent(label: "local.appcleaner.native.login")

  public let label: String
  public let folder: URL

  public init(
    label: String,
    folder: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
  ) {
    self.label = label
    self.folder = folder
  }

  public var plistURL: URL { folder.appendingPathComponent("\(label).plist") }
  public var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

  public var installedExecutable: String? {
    guard let data = try? Data(contentsOf: plistURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return (plist["ProgramArguments"] as? [String])?.first
  }

  public func install(executable: String) throws {
    let plist: [String: Any] = [
      "Label": label,
      "ProgramArguments": [executable, Self.backgroundArgument],
      "RunAtLoad": true,
      "LimitLoadToSessionType": "Aqua",
      "ProcessType": "Interactive",
    ]
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: plistURL, options: .atomic)
  }

  public func remove() throws {
    guard isInstalled else { return }
    try FileManager.default.removeItem(at: plistURL)
  }
}
