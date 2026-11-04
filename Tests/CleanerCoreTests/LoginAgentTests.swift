import Foundation
import XCTest

@testable import CleanerCore

final class LoginAgentTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("LoginAgent-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let folder { try? FileManager.default.removeItem(at: folder) }
  }

  func testInstallWritesBackgroundLoginAgentForTheExecutable() throws {
    let agent = LoginAgent(label: "local.test.login", folder: folder)
    XCTAssertFalse(agent.isInstalled)

    try agent.install(executable: "/Applications/Test.app/Contents/MacOS/Test")

    XCTAssertTrue(agent.isInstalled)
    let data = try Data(contentsOf: agent.plistURL)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    XCTAssertEqual(plist["Label"] as? String, "local.test.login")
    XCTAssertEqual(
      plist["ProgramArguments"] as? [String],
      ["/Applications/Test.app/Contents/MacOS/Test", LoginAgent.backgroundArgument])
    XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
    XCTAssertEqual(agent.installedExecutable, "/Applications/Test.app/Contents/MacOS/Test")
  }

  func testReinstallFollowsTheAppWhenItMoves() throws {
    let agent = LoginAgent(label: "local.test.login", folder: folder)
    try agent.install(executable: "/Users/x/Downloads/Test.app/Contents/MacOS/Test")
    try agent.install(executable: "/Applications/Test.app/Contents/MacOS/Test")
    XCTAssertEqual(agent.installedExecutable, "/Applications/Test.app/Contents/MacOS/Test")
  }

  func testRemoveDeletesTheAgent() throws {
    let agent = LoginAgent(label: "local.test.login", folder: folder)
    try agent.install(executable: "/Applications/Test.app/Contents/MacOS/Test")
    try agent.remove()
    XCTAssertFalse(agent.isInstalled)
    XCTAssertNoThrow(try agent.remove(), "removing twice is harmless")
  }
}
