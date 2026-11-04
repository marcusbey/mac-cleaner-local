import Foundation
import XCTest

@testable import CleanerCore

final class DiskSafetyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let day: TimeInterval = 86_400

  private func candidate(
    _ path: String, _ category: DiskCleanupCategory, ageDays: Double?,
    openedDaysAgo: Double? = nil
  ) -> DiskCleanupCandidate {
    DiskCleanupCandidate(
      url: URL(fileURLWithPath: "/Users/u/\(path)"), category: category, bytes: 1,
      modified: ageDays.map { now.addingTimeInterval(-$0 * day) }, reason: "",
      ownerBundleID: nil, scopeRoot: URL(fileURLWithPath: "/Users/u"),
      lastOpened: openedDaysAgo.map { now.addingTimeInterval(-$0 * day) })
  }

  func testAppCachesAreSafe() {
    let rating = DiskCleanupSafety.assess(
      candidate("Library/Caches/com.example.app", .cache, ageDays: 2), now: now)
    XCTAssertEqual(rating.level, .safe)
  }

  func testDeveloperDownloadCachesAreLikelySafeBecauseTheyRedownload() {
    for name in ["ms-playwright", "Homebrew", "CocoaPods", "pip", "go-build", "Cypress"] {
      let rating = DiskCleanupSafety.assess(
        candidate("Library/Caches/\(name)", .cache, ageDays: 2), now: now)
      XCTAssertEqual(rating.level, .likelySafe, name)
      XCTAssertTrue(rating.note.contains("download"), name)
    }
  }

  func testOldLogsAreSafeButVeryRecentLogsAreLikelySafe() {
    XCTAssertEqual(
      DiskCleanupSafety.assess(candidate("Library/Logs/x", .logs, ageDays: 10), now: now).level,
      .safe)
    XCTAssertEqual(
      DiskCleanupSafety.assess(candidate("Library/Logs/x", .logs, ageDays: 0.2), now: now).level,
      .likelySafe)
  }

  func testInstallerIsLikelySafeOnlyWhenItsAppIsInstalled() {
    let installed: Set<String> = ["docker", "bravebrowser", "googlechrome", "cursor"]
    for file in ["Docker.dmg", "Brave-Browser-arm64.dmg", "googlechrome.dmg", "Cursor-darwin-universal-1.2.dmg"] {
      let rating = DiskCleanupSafety.assess(
        candidate("Downloads/\(file)", .largeDownload, ageDays: 3), now: now, installedApps: installed)
      XCTAssertEqual(rating.level, .likelySafe, file)
      XCTAssertTrue(rating.note.contains("already installed"), file)
    }
    let missing = DiskCleanupSafety.assess(
      candidate("Downloads/Figma.dmg", .largeDownload, ageDays: 90), now: now, installedApps: installed)
    XCTAssertEqual(missing.level, .review)
    XCTAssertTrue(missing.note.contains("not installed"))
  }

  func testAppKeysNormalizeNamesAndInstallerNoise() {
    XCTAssertEqual(DiskCleanupSafety.appKey("Brave Browser"), "bravebrowser")
    XCTAssertEqual(DiskCleanupSafety.installerKey("Brave-Browser-arm64-v1.84.2.dmg"), "bravebrowser")
    XCTAssertEqual(DiskCleanupSafety.installerKey("Install macOS Tahoe.dmg"), "installmacostahoe")
    XCTAssertEqual(DiskCleanupSafety.installerKey("Docker (1).dmg"), "docker")
    XCTAssertFalse(
      DiskCleanupSafety.matchesInstalled(installerKey: "go", installed: ["google"]),
      "short keys must not match by prefix")
  }

  func testDocumentsStayReviewButExplainWhenTheyWereLastOpened() {
    let stale = DiskCleanupSafety.assess(
      candidate("Downloads/movie.mov", .largeDownload, ageDays: 800, openedDaysAgo: 500), now: now)
    XCTAssertEqual(stale.level, .review)
    XCTAssertTrue(stale.note.contains("Not opened in over a year"))

    let never = DiskCleanupSafety.assess(
      candidate("Downloads/archive.zip", .largeDownload, ageDays: 60), now: now)
    XCTAssertTrue(never.note.contains("No record of it being opened"))

    let recent = DiskCleanupSafety.assess(
      candidate("Downloads/deck.key", .largeDownload, ageDays: 60, openedDaysAgo: 2), now: now)
    XCTAssertTrue(recent.note.contains("Opened 2 days ago"))
  }
}
