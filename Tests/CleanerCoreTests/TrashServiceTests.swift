import Foundation
import XCTest
@testable import CleanerCore

final class TrashServiceTests: XCTestCase {
    func testMoveToTrashRejectsApplicationOutsideAllowedRootsWithoutMovingIt() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashServiceTests-\(UUID().uuidString)", isDirectory: true)
        let appURL = fixtureRoot.appendingPathComponent("Unsafe.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let app = AppRecord(
            id: appURL.path,
            name: "Unsafe",
            bundleID: "com.example.unsafe-fixture",
            url: appURL,
            version: "1",
            modified: nil,
            bytes: 0
        )

        XCTAssertThrowsError(try TrashService.moveToTrash(app: app, files: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
    }

    func testCanonicalValidationRejectsSymlinkWithoutMovingTarget() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashServiceSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let target = fixtureRoot.appendingPathComponent("Target.app", isDirectory: true)
        let link = fixtureRoot.appendingPathComponent("Link.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        XCTAssertThrowsError(try TrashService.validateCanonicalNonSymlink(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testRelatedFileValidationAcceptsSubsetAndRefreshesSize() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashRelatedTests-\(UUID().uuidString)", isDirectory: true)
        let home = fixtureRoot.appendingPathComponent("Home", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 9).write(to: cache.appendingPathComponent("data"))
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let app = AppRecord(
            id: "/Applications/Fixture.app",
            name: "Fixture",
            bundleID: "com.example.fixture",
            url: URL(fileURLWithPath: "/Applications/Fixture.app"),
            version: "1",
            modified: nil,
            bytes: 0
        )
        let staleSelection = RelatedFile(id: cache.path, url: cache, category: "Caches", bytes: 1)

        let validated = try TrashService.validatedRelatedFiles(
            [staleSelection],
            for: app,
            home: home
        )

        XCTAssertEqual(validated.map(\.url.path), [cache.path])
        XCTAssertEqual(validated.first?.bytes, 9)
    }

    func testRelatedFileValidationRejectsUnknownAndDuplicatePaths() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashStaleTests-\(UUID().uuidString)", isDirectory: true)
        let home = fixtureRoot.appendingPathComponent("Home", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let app = AppRecord(
            id: "/Applications/Fixture.app",
            name: "Fixture",
            bundleID: "com.example.fixture",
            url: URL(fileURLWithPath: "/Applications/Fixture.app"),
            version: "1",
            modified: nil,
            bytes: 0
        )
        let discovered = try XCTUnwrap(AppScanner.relatedFiles(for: app, home: home).first)
        let unknownURL = home.appendingPathComponent("Library/Caches/com.example.other")
        let unknown = RelatedFile(id: unknownURL.path, url: unknownURL, category: "Caches", bytes: 0)

        XCTAssertThrowsError(try TrashService.validatedRelatedFiles([unknown], for: app, home: home))
        XCTAssertThrowsError(try TrashService.validatedRelatedFiles([discovered, discovered], for: app, home: home))
    }

    func testRecordedBundleIdentifierMustMatchApplicationOnDisk() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashBundleIDTests-\(UUID().uuidString)", isDirectory: true)
        let appURL = fixtureRoot.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.actual"],
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let forged = AppRecord(
            id: appURL.path,
            name: "Fixture",
            bundleID: "com.example.forged",
            url: appURL,
            version: "1",
            modified: nil,
            bytes: 0
        )

        XCTAssertThrowsError(try TrashService.validateRecordedBundleIdentifier(forged, at: appURL))
    }
}
