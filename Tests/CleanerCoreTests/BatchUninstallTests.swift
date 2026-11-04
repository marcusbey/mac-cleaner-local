import Foundation
import XCTest

@testable import CleanerCore

final class BatchUninstallTests: XCTestCase {
  func testRetainedCopyProtectsRelatedData() throws {
    let name = "com.cleanerqatest.copy\(UUID().uuidString.replacingOccurrences(of:"-",with:""))"
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Caches/\(name)")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cache) }
    let a = record("/Applications/One.app", name)
    let b = record("/Applications/Two.app", name)
    let plan = BatchUninstall.review(apps: [a], installed: [a, b])
    XCTAssertTrue(plan.files.isEmpty)
    XCTAssertEqual(plan.preservedSharedIDs, [name])
    XCTAssertEqual(BatchUninstall.review(apps: [a, b], installed: [a, b]).files.count, 1)
  }
  func testAllAppsPreflightBeforeAnyMove() throws {
    let outside = record("/tmp/Outside.app", "com.fixture.outside")
    XCTAssertThrowsError(try BatchUninstall.moveToTrash(apps: [outside], files: []))
    XCTAssertThrowsError(try BatchUninstall.moveToTrash(apps: [], files: []))
    XCTAssertThrowsError(try BatchUninstall.moveToTrash(apps: [outside, outside], files: []))
  }
  func testRealBatchTrashAndRecovery() throws {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(
      "Applications/CleanerBatchQA-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    var apps: [AppRecord] = []
    for name in ["First", "Second"] {
      let url = root.appendingPathComponent("\(name).app")
      try fm.createDirectory(
        at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
      let id = "com.cleanerqatest.\(UUID().uuidString)"
      let data = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleVersion": "1"],
        format: .xml, options: 0)
      try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
      apps.append(record(url.path, id))
    }
    let moved = try BatchUninstall.moveToTrash(apps: apps, files: [])
    XCTAssertEqual(moved.count, 2)
    for (index, url) in moved.enumerated() {
      XCTAssertFalse(fm.fileExists(atPath: apps[index].url.path))
      XCTAssertTrue(fm.fileExists(atPath: url.path))
      try fm.moveItem(at: url, to: apps[index].url)
      XCTAssertTrue(fm.fileExists(atPath: apps[index].url.path))
    }
  }
  func testReplacementAfterPreflightIsNotTrashed() throws {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(
      "Applications/CleanerRaceQA-\(UUID().uuidString)")
    let url = root.appendingPathComponent("Fixture.app")
    let backup = root.appendingPathComponent("Original.app")
    try fm.createDirectory(
      at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let id = "com.cleanerqatest.race"
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": id, "CFBundleVersion": "1"], format: .xml, options: 0
    )
    try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    XCTAssertThrowsError(
      try BatchUninstall.moveToTrash(
        apps: [record(url.path, id)], files: [],
        beforeMove: { path in
          try fm.moveItem(at: path, to: backup)
          try fm.createDirectory(
            at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
          try data.write(to: path.appendingPathComponent("Contents/Info.plist"))
        }))
    XCTAssertTrue(fm.fileExists(atPath: url.path))
    XCTAssertTrue(fm.fileExists(atPath: backup.path))
  }
  private func record(_ path: String, _ bundle: String) -> AppRecord {
    AppRecord(
      id: path, name: URL(fileURLWithPath: path).lastPathComponent, bundleID: bundle,
      url: URL(fileURLWithPath: path), version: "1", modified: nil, bytes: 0)
  }
}
