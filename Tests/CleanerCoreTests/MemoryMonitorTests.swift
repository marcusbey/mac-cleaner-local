import XCTest

@testable import CleanerCore

final class MemoryMonitorTests: XCTestCase {
  func testBreakdownConvertsRawPageCountersWithoutDoubleCountingInactiveCategories() {
    let breakdown = MemoryBreakdown(
      pageSize: 4096,
      activePages: 10,
      inactivePages: 20,
      wiredPages: 3,
      compressedPages: 4,
      freePages: 5,
      speculativePages: 2,
      purgeablePages: 1
    )

    XCTAssertEqual(breakdown.activeBytes, 40_960)
    XCTAssertEqual(breakdown.inactiveBytes, 81_920)
    XCTAssertEqual(breakdown.wiredBytes, 12_288)
    XCTAssertEqual(breakdown.compressedBytes, 16_384)
    XCTAssertEqual(breakdown.freeBytes, 20_480)
    XCTAssertEqual(breakdown.speculativeBytes, 8_192)
    XCTAssertEqual(breakdown.purgeableBytes, 4_096)
    XCTAssertEqual(breakdown.approximateUsedBytes, 69_632)
  }

  func testSnapshotClampsApproximateUsedMemoryToPhysicalCapacity() {
    let breakdown = MemoryBreakdown(
      pageSize: 4096,
      activePages: .max,
      inactivePages: 1,
      wiredPages: 1,
      compressedPages: 1,
      freePages: 1,
      speculativePages: 1,
      purgeablePages: 1
    )
    let snapshot = MemorySnapshot(
      date: Date(),
      physicalBytes: 1_000,
      breakdown: breakdown,
      swap: SwapUsage(totalBytes: 10, usedBytes: 4),
      pressure: .unknown,
      applications: []
    )

    XCTAssertEqual(snapshot.approximateUsedBytes, 1_000)
  }

  func testUnavailableSwapIsDistinctFromZeroSwapUsage() {
    XCTAssertFalse(SwapUsage.unavailable.isAvailable)
    XCTAssertTrue(SwapUsage(totalBytes: 0, usedBytes: 0).isAvailable)
  }

  func testLiveSnapshotHasPlausibleInvariants() throws {
    let snapshot = try MemoryMonitor.snapshot(includeApplications: false)

    XCTAssertGreaterThan(snapshot.physicalBytes, 0)
    XCTAssertLessThanOrEqual(snapshot.approximateUsedBytes, snapshot.physicalBytes)
    if snapshot.swap.isAvailable {
      XCTAssertLessThanOrEqual(snapshot.swap.usedBytes, snapshot.swap.totalBytes)
    }
    XCTAssertTrue(snapshot.applications.isEmpty)
  }

  func testRunningApplicationSamplesAreUniqueAndSorted() throws {
    let snapshot = try MemoryMonitor.snapshot(includeApplications: true)
    let pids = snapshot.applications.map(\.pid)

    XCTAssertEqual(Set(pids).count, pids.count)
    XCTAssertEqual(
      snapshot.applications.map(\.footprintBytes),
      snapshot.applications.map(\.footprintBytes).sorted(by: >)
    )
    XCTAssertTrue(snapshot.applications.allSatisfy { $0.pid > 0 && !$0.name.isEmpty })
  }
}
