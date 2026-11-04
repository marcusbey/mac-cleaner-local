import Foundation
import XCTest

@testable import CleanerCore

final class DeveloperCleanupTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("DevCleanup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let home { try? FileManager.default.removeItem(at: home) }
  }

  private func file(_ path: String, kilobytes: Int = 8, ageDays: Double = 0) throws {
    let url = home.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: kilobytes * 1024).write(to: url)
    if ageDays > 0 { try age(url.deletingLastPathComponent(), days: ageDays) }
  }

  private func age(_ url: URL, days: Double) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
  }

  func testDeveloperScanFindsKnownToolFoldersAndRatesThem() throws {
    try file("Library/Developer/Xcode/DerivedData/MyApp-abc/Build/x.o")
    try file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist")
    try file(".npm/_cacache/index/x")
    try file(".npm/_logs/keep.log")
    try file(".cache/pip/http/x")

    let result = DeveloperCleanupScanner.scan(home: home)
    let byName = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.url.lastPathComponent, $0) })

    XCTAssertEqual(Set(byName.keys), ["MyApp-abc", "2026-01-01", "_cacache", "pip"])
    XCTAssertTrue(result.candidates.allSatisfy { $0.category == .developer && $0.bytes > 0 })
    XCTAssertEqual(DiskCleanupSafety.assess(try XCTUnwrap(byName["MyApp-abc"])).level, .safe)
    XCTAssertEqual(DiskCleanupSafety.assess(try XCTUnwrap(byName["_cacache"])).level, .likelySafe)
    XCTAssertEqual(DiskCleanupSafety.assess(try XCTUnwrap(byName["2026-01-01"])).level, .review)
  }

  func testDependencyScanFindsTopLevelNodeModulesOnly() throws {
    try file("Projects/old-app/node_modules/react/index.js", ageDays: 90)
    try file("Projects/old-app/node_modules/react/node_modules/nested/x.js")
    try file("Projects/new-app/node_modules/vite/index.js")
    try file("Projects/.hidden/node_modules/x.js")
    try age(home.appendingPathComponent("Projects/old-app/node_modules"), days: 90)

    let result = DeveloperCleanupScanner.scanDependencies(
      in: home.appendingPathComponent("Projects"))
    let paths = result.candidates.map {
      $0.url.path.replacingOccurrences(of: home.standardizedFileURL.path + "/", with: "")
    }

    XCTAssertEqual(Set(paths), ["Projects/old-app/node_modules", "Projects/new-app/node_modules"])
    XCTAssertTrue(result.candidates.allSatisfy { $0.category == .dependencies })
  }

  func testDependencySafetyUsesAgeAndProtectsWorktrees() throws {
    let now = Date()
    func candidate(_ path: String, ageDays: Double) -> DiskCleanupCandidate {
      DiskCleanupCandidate(
        url: URL(fileURLWithPath: "/Users/u/\(path)"), category: .dependencies, bytes: 1,
        modified: now.addingTimeInterval(-ageDays * 86_400), reason: "", ownerBundleID: nil,
        scopeRoot: URL(fileURLWithPath: "/Users/u"))
    }
    XCTAssertEqual(
      DiskCleanupSafety.assess(candidate("Projects/a/node_modules", ageDays: 60), now: now).level,
      .likelySafe)
    XCTAssertEqual(
      DiskCleanupSafety.assess(candidate("Projects/a/node_modules", ageDays: 3), now: now).level,
      .review)
    let worktree = DiskCleanupSafety.assess(
      candidate("Projects/a/worktrees/feature/node_modules", ageDays: 90), now: now)
    XCTAssertEqual(worktree.level, .review)
    XCTAssertTrue(worktree.note.contains("worktree"))
  }

  func testNewCategoriesMoveToTrashButForgedOnesAreRejected() throws {
    try file("Library/Developer/Xcode/DerivedData/Disposable-\(UUID().uuidString)/x.o")
    try file("Projects/app/node_modules/x.js")
    let developer = try XCTUnwrap(DeveloperCleanupScanner.scan(home: home).candidates.first)
    let dependency = try XCTUnwrap(
      DeveloperCleanupScanner.scanDependencies(in: home.appendingPathComponent("Projects"))
        .candidates.first)

    let forgedURL = home.appendingPathComponent("Projects/app/src")
    try FileManager.default.createDirectory(at: forgedURL, withIntermediateDirectories: true)
    let forged = DiskCleanupCandidate(
      url: forgedURL, category: .dependencies, bytes: 0, modified: nil, reason: "",
      ownerBundleID: nil, scopeRoot: home.appendingPathComponent("Projects"))
    XCTAssertThrowsError(
      try DiskCleanupTrashService.moveToTrash(
        [forged], allowedRoots: [forged.scopeRoot], runningBundleIDs: []))

    let outcome = try DiskCleanupTrashService.moveToTrash(
      [developer, dependency], allowedRoots: [developer.scopeRoot, dependency.scopeRoot],
      runningBundleIDs: [])
    XCTAssertEqual(outcome.moved.count, 2)
    for url in outcome.moved { try? FileManager.default.removeItem(at: url) }
  }
}
