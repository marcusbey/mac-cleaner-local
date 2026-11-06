import Foundation
import XCTest

@testable import CleanerCore

final class StartupItemsTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("Startup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let folder { try? FileManager.default.removeItem(at: folder) }
  }

  private func plist(_ name: String, _ values: [String: Any]) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    return url
  }

  func testParsesProgramOwnerAndLoginBehavior() throws {
    let url = try plist(
      "com.logi.optionsplus.plist",
      [
        "Label": "com.logi.optionsplus",
        "ProgramArguments": [
          "/Library/Application Support/Removed-\(UUID().uuidString)/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent",
          "--silent",
        ],
        "RunAtLoad": true,
      ])
    let item = try XCTUnwrap(
      StartupItems.item(at: url, scope: .allUsers, disabled: [:], running: []))
    XCTAssertEqual(item.label, "com.logi.optionsplus")
    XCTAssertEqual(item.owner, "logioptionsplus_agent")
    XCTAssertEqual(item.vendor, "Logi")
    XCTAssertTrue(item.startsAtLogin)
    XCTAssertTrue(item.isEnabled)
    XCTAssertTrue(item.programMissing)
    XCTAssertFalse(item.isRunning)
  }

  func testDisabledOverridesAndPlistDisabledKey() throws {
    let program = folder.appendingPathComponent("tool")
    try Data([1]).write(to: program)
    let url = try plist(
      "dev.example.tool.plist", ["Label": "dev.example.tool", "Program": program.path])
    let off = try XCTUnwrap(
      StartupItems.item(at: url, scope: .user, disabled: ["dev.example.tool": true], running: []))
    XCTAssertFalse(off.isEnabled)
    XCTAssertFalse(off.programMissing)
    XCTAssertFalse(off.startsAtLogin)

    let running = try XCTUnwrap(
      StartupItems.item(at: url, scope: .user, disabled: [:], running: [program.path]))
    XCTAssertTrue(running.isRunning)
    XCTAssertEqual(running.owner, "tool")

    let declared = try plist(
      "dev.example.off.plist", ["Label": "dev.example.off", "Program": program.path, "Disabled": true])
    XCTAssertFalse(
      try XCTUnwrap(StartupItems.item(at: declared, scope: .user, disabled: [:], running: [])).isEnabled)
    XCTAssertTrue(
      try XCTUnwrap(
        StartupItems.item(at: declared, scope: .user, disabled: ["dev.example.off": false], running: [])
      ).isEnabled, "a launchctl enable override wins over the plist")
  }

  func testParsesLaunchctlPrintDisabled() {
    let output = """
      \tdisabled services = {
      \t\t"com.macpaw.CleanMyMac4.Menu" => enabled
      \t\t"jp.co.canon.helper" => disabled
      \t\t"com.example.true" => true
      \t}
      """
    XCTAssertEqual(
      StartupItems.parseDisabled(output),
      ["com.macpaw.CleanMyMac4.Menu": false, "jp.co.canon.helper": true, "com.example.true": true])
  }

  func testInvalidPlistIsSkipped() throws {
    let url = folder.appendingPathComponent("broken.plist")
    try Data("not a plist".utf8).write(to: url)
    XCTAssertNil(StartupItems.item(at: url, scope: .user, disabled: [:], running: []))
  }

  func testRemovalCommandForSharedItemsStopsThenMovesToTrash() throws {
    let program = folder.appendingPathComponent("tool")
    try Data([1]).write(to: program)
    let agent = try XCTUnwrap(
      StartupItems.item(
        at: try plist("com.adobe.ccxprocess.plist", ["Label": "com.adobe.ccxprocess", "Program": program.path]),
        scope: .allUsers, disabled: [:], running: []))
    let command = try StartupItems.removalCommand(
      for: agent, folder: folder.path, trash: "/Users/u/.Trash/x.plist", uid: 501)
    XCTAssertTrue(command.hasPrefix("/bin/launchctl bootout gui/501/com.adobe.ccxprocess"))
    XCTAssertTrue(command.contains("/bin/mv -f '\(agent.url.path)' '/Users/u/.Trash/x.plist'"))

    let daemon = try XCTUnwrap(
      StartupItems.item(
        at: try plist("com.adobe.agsservice.plist", ["Label": "com.adobe.agsservice", "Program": program.path]),
        scope: .system, disabled: [:], running: []))
    XCTAssertTrue(
      try StartupItems.removalCommand(for: daemon, folder: folder.path, trash: "/t/x", uid: 501)
        .hasPrefix("/bin/launchctl bootout system/com.adobe.agsservice"))

    XCTAssertThrowsError(
      try StartupItems.removalCommand(for: agent, folder: "/Library/LaunchAgents", trash: "/t/x", uid: 501),
      "a file outside the scope's folder is refused")
  }
}
