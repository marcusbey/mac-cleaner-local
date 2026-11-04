import Foundation
import XCTest

@testable import CleanerCore

final class SizeTreeTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SizeTreeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func file(_ path: String, kilobytes: Int) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: kilobytes * 1024).write(to: url)
  }

  func testFolderSizesRollUpAndChildrenSortLargestFirst() throws {
    try file("big/a.bin", kilobytes: 400)
    try file("big/nested/b.bin", kilobytes: 200)
    try file("small/c.bin", kilobytes: 50)
    try file("top.bin", kilobytes: 100)

    let tree = SizeTree.scan(root, minimumShare: 0)

    XCTAssertEqual(tree.root.children.map(\.name), ["big", "top.bin", "small"])
    let big = try XCTUnwrap(tree.root.children.first)
    XCTAssertTrue(big.isDirectory)
    XCTAssertEqual(big.bytes, big.children.reduce(0) { $0 + $1.bytes })
    XCTAssertEqual(tree.root.bytes, tree.root.children.reduce(0) { $0 + $1.bytes })
    XCTAssertGreaterThanOrEqual(big.bytes, 600 * 1024)
    XCTAssertEqual(tree.fileCount, 4)
  }

  func testTinyItemsAreMergedIntoOneSmallerItemsNode() throws {
    try file("huge.bin", kilobytes: 2000)
    for index in 0..<5 { try file("tiny\(index).bin", kilobytes: 4) }

    let tree = SizeTree.scan(root, minimumShare: 0.05)

    XCTAssertEqual(tree.root.children.count, 2)
    let other = try XCTUnwrap(tree.root.children.last)
    XCTAssertTrue(other.isAggregate)
    XCTAssertNil(other.url)
    XCTAssertEqual(other.name, "5 smaller items")
    XCTAssertEqual(tree.root.bytes, tree.root.children.reduce(0) { $0 + $1.bytes })
  }

  func testSymlinksAreNotFollowed() throws {
    try file("real/data.bin", kilobytes: 500)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link"),
      withDestinationURL: root.appendingPathComponent("real"))

    let tree = SizeTree.scan(root, minimumShare: 0)

    XCTAssertEqual(tree.root.children.map(\.name), ["real"])
  }

  func testCancellationStopsScan() throws {
    for index in 0..<50 { try file("d\(index)/f.bin", kilobytes: 1) }
    var calls = 0
    let tree = SizeTree.scan(root, minimumShare: 0) {
      calls += 1
      return calls > 3
    }
    XCTAssertTrue(tree.cancelled)
  }

  func testOnlyItemsInsideHomeAtLeastTwoLevelsDeepAreTrashable() {
    let home = URL(fileURLWithPath: "/Users/someone")
    XCTAssertTrue(SizeTree.canTrash(URL(fileURLWithPath: "/Users/someone/Downloads/x.dmg"), home: home))
    XCTAssertFalse(SizeTree.canTrash(URL(fileURLWithPath: "/Users/someone/Downloads"), home: home))
    XCTAssertFalse(SizeTree.canTrash(home, home: home))
    XCTAssertFalse(SizeTree.canTrash(URL(fileURLWithPath: "/Users/someone/../x/y"), home: home))
    XCTAssertFalse(SizeTree.canTrash(URL(fileURLWithPath: "/System/Library/x"), home: home))
    XCTAssertFalse(SizeTree.canTrash(URL(fileURLWithPath: "/Users/someoneelse/a/b"), home: home))
  }

  func testRemovingNodeSubtractsItsSizeFromEveryAncestor() throws {
    try file("a/b/drop.bin", kilobytes: 300)
    try file("a/b/keep.bin", kilobytes: 100)
    let tree = SizeTree.scan(root, minimumShare: 0)
    let drop = root.appendingPathComponent("a/b/drop.bin").standardizedFileURL.path
    let dropBytes = try XCTUnwrap(
      tree.root.children.first?.children.first?.children.first { $0.id == drop }
    ).bytes

    let updated = tree.root.removing(id: drop)

    XCTAssertEqual(updated.bytes, tree.root.bytes - dropBytes)
    XCTAssertEqual(updated.children.first?.children.first?.children.map(\.name), ["keep.bin"])
    XCTAssertEqual(tree.root.children.first?.children.first?.children.count, 2)
  }

  func testBulkListingMatchesFoundationAllocatedSizes() throws {
    try file("one.bin", kilobytes: 123)
    try file("folder/two.bin", kilobytes: 7)
    let entries = try XCTUnwrap(SizeTree.list(root.path))
    XCTAssertEqual(Set(entries.map(\.name)), ["one.bin", "folder"])
    let one = try XCTUnwrap(entries.first { $0.name == "one.bin" })
    let expected = try root.appendingPathComponent("one.bin")
      .resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
    XCTAssertEqual(one.bytes, Int64(try XCTUnwrap(expected)))
    XCTAssertTrue(try XCTUnwrap(entries.first { $0.name == "folder" }).isDirectory)
    XCTAssertNil(SizeTree.list(root.appendingPathComponent("missing").path))
  }

  func testLiveProgressReportsGrowingPartialTreesAndCurrentFolder() throws {
    for index in 0..<4 { try file("d\(index)/f.bin", kilobytes: 64) }
    final class Box: @unchecked Sendable { var updates: [SizeTreeProgress] = [] }
    let box = Box()

    let tree = SizeTree.scan(root, minimumShare: 0, updateInterval: 0) { box.updates.append($0) }

    XCTAssertFalse(box.updates.isEmpty)
    let bytes = box.updates.map(\.bytes)
    XCTAssertEqual(bytes, bytes.sorted(), "found bytes only grow")
    XCTAssertTrue(box.updates.allSatisfy { $0.currentFolder.hasPrefix(self.root.standardizedFileURL.path) })
    let last = try XCTUnwrap(box.updates.last)
    XCTAssertLessThanOrEqual(last.partial.bytes, tree.root.bytes)
    XCTAssertEqual(last.partial.id, tree.root.id)
  }
}
