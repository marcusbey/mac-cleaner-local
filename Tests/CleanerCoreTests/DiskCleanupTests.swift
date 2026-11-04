import Foundation
import XCTest

@testable import CleanerCore

final class DiskCleanupTests: XCTestCase {
  private var root: URL!
  private var home: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DiskCleanupTests-\(UUID().uuidString)", isDirectory: true)
    home = root.appendingPathComponent("Home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testCacheScanIsDirectBoundedAndProtectsRunningAndSystemOwners() throws {
    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    try makeDirectory("Library/Caches/com.example.orphan", bytes: 11)
    try makeDirectory("Library/Caches/com.example.running", bytes: 7)
    try makeDirectory("Library/Caches/com.apple.Safari", bytes: 5)
    try makeDirectory("Library/Caches/Vendor/com.example.nested", bytes: 13)
    let target = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: caches.appendingPathComponent("com.example.link"), withDestinationURL: target)

    let result = DiskCleanupScanner.scanJunk(
      roots: [.init(category: .cache, url: caches)],
      runningBundleIDs: ["com.example.running"],
      limit: 10
    )

    XCTAssertEqual(
      result.candidates.map(\.url.lastPathComponent), ["Vendor", "com.example.orphan"])
    XCTAssertFalse(result.candidates.contains { $0.url.lastPathComponent == "com.example.nested" })
    XCTAssertTrue(result.candidates.allSatisfy { !$0.selectedByDefault })
    XCTAssertTrue(result.errors.isEmpty)
  }

  func testScanReportsUnreadableOrMissingRootsAndHonorsLimit() throws {
    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    try makeDirectory("Library/Caches/a.example.one", bytes: 1)
    try makeDirectory("Library/Caches/a.example.two", bytes: 1)

    let result = DiskCleanupScanner.scanJunk(
      roots: [
        .init(category: .logs, url: home.appendingPathComponent("Missing")),
        .init(category: .cache, url: caches),
      ],
      runningBundleIDs: [],
      limit: 1
    )

    XCTAssertEqual(result.candidates.count, 1)
    XCTAssertTrue(result.truncated)
    XCTAssertEqual(result.errors.count, 1)
  }

  func testDownloadsScanFindsOnlyLargeRegularFilesAndSkipsSymlinks() throws {
    let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 120).write(to: downloads.appendingPathComponent("large.zip"))
    try Data(repeating: 1, count: 20).write(to: downloads.appendingPathComponent("small.zip"))
    let nested = downloads.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 2, count: 140).write(to: nested.appendingPathComponent("video.mov"))
    try FileManager.default.createSymbolicLink(
      at: downloads.appendingPathComponent("linked.mov"),
      withDestinationURL: nested.appendingPathComponent("video.mov"))

    let result = DiskCleanupScanner.scanLargeFiles(
      folder: downloads, minimumBytes: 100, limit: 10)

    XCTAssertEqual(Set(result.candidates.map(\.url.lastPathComponent)), ["large.zip", "video.mov"])
    XCTAssertTrue(result.errors.isEmpty)
  }

  func testDownloadsScanDoesNotEnterApplicationOrLibraryPackages() throws {
    let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
    let appBinary = downloads.appendingPathComponent("Tool.app/Contents/MacOS/Tool")
    let photoAsset = downloads.appendingPathComponent("Photos.photoslibrary/original.mov")
    try FileManager.default.createDirectory(
      at: appBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: photoAsset.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 150).write(to: appBinary)
    try Data(repeating: 1, count: 150).write(to: photoAsset)
    try Data(repeating: 1, count: 150).write(to: downloads.appendingPathComponent("archive.zip"))

    let result = DiskCleanupScanner.scanLargeFiles(
      folder: downloads, minimumBytes: 100, limit: 10)

    XCTAssertEqual(result.candidates.map(\.url.lastPathComponent), ["archive.zip"])
  }

  func testScanCancellationStopsBeforeReturningMoreCandidates() throws {
    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    for index in 0..<5 { try makeDirectory("Library/Caches/com.example.\(index)", bytes: 1) }
    var checks = 0
    let result = DiskCleanupScanner.scanJunk(
      roots: [.init(category: .cache, url: caches)],
      runningBundleIDs: [],
      limit: 10,
      shouldCancel: {
        checks += 1
        return checks > 2
      }
    )
    XCTAssertTrue(result.cancelled)
    XCTAssertLessThan(result.candidates.count, 5)
  }

  func testCancellationInterruptsRecursiveSizeMeasurement() throws {
    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    for index in 0..<20 {
      try makeDirectory("Library/Caches/com.example.deep/\(index)", bytes: 1)
    }
    var checks = 0
    let result = DiskCleanupScanner.scanJunk(
      roots: [.init(category: .cache, url: caches)],
      runningBundleIDs: [],
      limit: 10,
      shouldCancel: {
        checks += 1
        return checks > 5
      }
    )
    XCTAssertTrue(result.cancelled)
    XCTAssertTrue(result.candidates.isEmpty)
  }

  func testTrashRejectsDuplicateOutsideRunningAndChangedSelections() throws {
    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    try makeDirectory("Library/Caches/com.example.safe", bytes: 4)
    let candidate = try XCTUnwrap(
      DiskCleanupScanner.scanJunk(
        roots: [.init(category: .cache, url: caches)], runningBundleIDs: [], limit: 10
      ).candidates.first)

    XCTAssertThrowsError(
      try DiskCleanupTrashService.moveToTrash(
        [candidate, candidate], allowedRoots: [caches], runningBundleIDs: []))
    XCTAssertThrowsError(
      try DiskCleanupTrashService.moveToTrash(
        [candidate], allowedRoots: [caches], runningBundleIDs: ["com.example.safe"]))

    let forgedOwner = DiskCleanupCandidate(
      url: candidate.url, category: .cache, bytes: candidate.bytes,
      modified: candidate.modified, reason: candidate.reason,
      ownerBundleID: nil, scopeRoot: caches)
    XCTAssertThrowsError(
      try DiskCleanupTrashService.moveToTrash(
        [forgedOwner], allowedRoots: [caches], runningBundleIDs: ["com.example.safe"]))

    let appleURL = caches.appendingPathComponent("com.apple.Finder", isDirectory: true)
    try FileManager.default.createDirectory(at: appleURL, withIntermediateDirectories: true)
    let forgedApple = DiskCleanupCandidate(
      url: appleURL, category: .cache, bytes: 0, modified: nil,
      reason: "forged", ownerBundleID: nil, scopeRoot: caches)
    XCTAssertThrowsError(
      try DiskCleanupTrashService.moveToTrash(
        [forgedApple], allowedRoots: [caches], runningBundleIDs: []))

    let wrongCategory = DiskCleanupCandidate(
      url: candidate.url, category: .logs, bytes: candidate.bytes,
      modified: candidate.modified, reason: "forged",
      ownerBundleID: candidate.ownerBundleID, scopeRoot: caches)
    XCTAssertThrowsError(
      try DiskCleanupTrashService.moveToTrash(
        [wrongCategory], allowedRoots: [caches], runningBundleIDs: []))

    if let currentBundleID = Bundle.main.bundleIdentifier {
      let selfURL = caches.appendingPathComponent(currentBundleID, isDirectory: true)
      try FileManager.default.createDirectory(at: selfURL, withIntermediateDirectories: true)
      let forgedSelf = DiskCleanupCandidate(
        url: selfURL, category: .cache, bytes: 0, modified: nil,
        reason: "forged", ownerBundleID: nil, scopeRoot: caches)
      XCTAssertThrowsError(
        try DiskCleanupTrashService.moveToTrash(
          [forgedSelf], allowedRoots: [caches], runningBundleIDs: []))
    }

    let outsideURL = root.appendingPathComponent("outside.txt")
    try Data([1]).write(to: outsideURL)
    let outside = DiskCleanupCandidate(
      url: outsideURL, category: .cache, bytes: 1, modified: nil,
      reason: "forged", ownerBundleID: nil, scopeRoot: caches)
    XCTAssertThrowsError(
      try DiskCleanupTrashService.moveToTrash(
        [outside], allowedRoots: [caches], runningBundleIDs: []))

    try FileManager.default.removeItem(at: candidate.url)
    try FileManager.default.createDirectory(at: candidate.url, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try DiskCleanupTrashService.moveToTrash(
        [candidate], allowedRoots: [caches], runningBundleIDs: []))
    XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.url.path))
  }

  func testBatchMovesValidItemsAndReportsSkippedOnes() throws {
    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    try makeDirectory("Library/Caches/com.example.busy", bytes: 4)
    try makeDirectory("Library/Caches/com.example.idle", bytes: 4)
    let candidates = DiskCleanupScanner.scanJunk(
      roots: [.init(category: .cache, url: caches)], runningBundleIDs: [], limit: 10
    ).candidates
    XCTAssertEqual(candidates.count, 2)

    let outcome = try DiskCleanupTrashService.moveToTrash(
      candidates, allowedRoots: [caches], runningBundleIDs: ["com.example.busy"])

    XCTAssertEqual(outcome.moved.count, 1)
    XCTAssertEqual(outcome.skipped.map(\.url.lastPathComponent), ["com.example.busy"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: caches.appendingPathComponent("com.example.busy").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: caches.appendingPathComponent("com.example.idle").path))
    for url in outcome.moved { try? FileManager.default.removeItem(at: url) }
  }

  func testCacheFolderWrittenAfterScanIsStillRemovable() throws {
    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    try makeDirectory("Library/Caches/com.example.active", bytes: 4)
    let candidate = try XCTUnwrap(
      DiskCleanupScanner.scanJunk(
        roots: [.init(category: .cache, url: caches)], runningBundleIDs: [], limit: 10
      ).candidates.first)
    try Data([9]).write(to: candidate.url.appendingPathComponent("written-later"))

    let outcome = try DiskCleanupTrashService.moveToTrash(
      [candidate], allowedRoots: [caches], runningBundleIDs: [])

    XCTAssertEqual(outcome.moved.count, 1)
    for url in outcome.moved { try? FileManager.default.removeItem(at: url) }
  }

  func testRealTrashMoveReturnsRecoverableDestination() throws {
    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    try makeDirectory("Library/Caches/com.example.disposable-\(UUID().uuidString)", bytes: 3)
    let candidate = try XCTUnwrap(
      DiskCleanupScanner.scanJunk(
        roots: [.init(category: .cache, url: caches)], runningBundleIDs: [], limit: 10
      ).candidates.first)

    let destination = try XCTUnwrap(
      DiskCleanupTrashService.moveToTrash(
        [candidate], allowedRoots: [caches], runningBundleIDs: []
      ).moved.first)
    XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.url.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    try FileManager.default.moveItem(at: destination, to: candidate.url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.url.path))
  }

  func testVolumeUsageMaintainsArithmeticInvariants() throws {
    let usage = try DiskVolumeUsage.read(for: home)
    XCTAssertGreaterThan(usage.totalBytes, 0)
    XCTAssertGreaterThanOrEqual(usage.availableBytes, 0)
    XCTAssertLessThanOrEqual(usage.availableBytes, usage.totalBytes)
    XCTAssertEqual(usage.usedBytes, usage.totalBytes - usage.availableBytes)
  }

  private func makeDirectory(_ relativePath: String, bytes: Int) throws {
    let url = home.appendingPathComponent(relativePath, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(repeating: 1, count: bytes).write(to: url.appendingPathComponent("payload"))
  }
}

extension DiskCleanupTests {
  func testKnownVendorAliasesProtectRunningApps() {
    XCTAssertEqual(DiskCleanupScanner.likelyBundleIdentifier("BraveSoftware"), "com.brave")
    XCTAssertTrue(DiskCleanupScanner.isProtected("com.brave", runningBundleIDs:["com.brave.Browser"]))
    XCTAssertTrue(DiskCleanupScanner.isProtected("com.openai.codex", runningBundleIDs:["com.openai.codex"]))
  }
}
