import Foundation
import XCTest
@testable import CleanerCore

final class RemainingFilesTests: XCTestCase {
    private var fixtureRoot: URL!
    private var home: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemainingFilesTests-\(UUID().uuidString)", isDirectory: true)
        home = fixtureRoot.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    func testScanFindsOnlyExactReverseDNSCandidatesAtApprovedLibraryRoots() throws {
        let bundleID = "com.example.orphan"
        let expected = [
            ("Caches", "Library/Caches/\(bundleID)", false),
            ("Containers", "Library/Containers/\(bundleID)", false),
            ("Application Scripts", "Library/Application Scripts/\(bundleID)", false),
            ("Preferences", "Library/Preferences/\(bundleID).plist", true),
            ("Application Support", "Library/Application Support/\(bundleID)", false),
            ("Logs", "Library/Logs/\(bundleID)", false),
            ("Saved Application State", "Library/Saved Application State/\(bundleID).savedState", false),
        ]
        for (_, relativePath, isFile) in expected {
            try createCandidate(relativePath, isFile: isFile, bytes: 7)
        }

        try createCandidate("Library/Caches/com.apple.Safari", isFile: false, bytes: 5)
        try createCandidate("Library/Caches/Google", isFile: false, bytes: 5)
        try createCandidate("Library/Caches/Vendor/com.example.nested", isFile: false, bytes: 5)
        try createCandidate("Library/Group Containers/com.example.container", isFile: false, bytes: 5)
        try createCandidate("Library/Preferences/com.example.orphan.extra.plist.backup", isFile: true, bytes: 5)

        let results = RemainingScanner.scan(
            installedApps: [],
            home: home,
            runningBundleIDs: [],
            applicationURLResolver: { _ in nil }
        )

        XCTAssertEqual(Set(results.map(\.url.path)), Set(expected.map { home.appendingPathComponent($0.1).path }))
        XCTAssertEqual(Set(results.map(\.category)), Set(expected.map(\.0)))
        XCTAssertTrue(results.allSatisfy { $0.bundleID == bundleID })
        XCTAssertTrue(results.allSatisfy { $0.reason == "Possible leftover for \(bundleID); no owning application was found." })
        XCTAssertTrue(results.allSatisfy { $0.category == "Containers" ? $0.bytes >= 7 : $0.bytes == 7 })
    }

    func testScanProtectsInstalledNestedRunningAndResolvedApplications() throws {
        let installedID = "com.example.installed"
        let helperID = "com.example.installed.helper"
        let extensionID = "com.example.installed.extension"
        let serviceID = "com.example.installed.service"
        let bundleHelperID = "com.example.installed.resources"
        let namespacedID = "com.example.installed.unlisted-helper"
        let runningID = "com.example.running"
        let elsewhereID = "com.example.elsewhere"
        let orphanID = "com.example.orphan"
        for id in [installedID, helperID, extensionID, serviceID, bundleHelperID, namespacedID, runningID, elsewhereID, orphanID] {
            try createCandidate("Library/Caches/\(id)", isFile: false, bytes: 1)
        }

        let appURL = fixtureRoot.appendingPathComponent("Applications/Fixture.app", isDirectory: true)
        try makeApplication(at: appURL, bundleID: installedID)
        try makeApplication(
            at: appURL.appendingPathComponent("Contents/Library/LoginItems/Helper.app", isDirectory: true),
            bundleID: helperID
        )
        try makeApplication(
            at: appURL.appendingPathComponent("Contents/PlugIns/Extension.appex", isDirectory: true),
            bundleID: extensionID
        )
        try makeApplication(
            at: appURL.appendingPathComponent("Contents/XPCServices/Service.xpc", isDirectory: true),
            bundleID: serviceID
        )
        try makeApplication(
            at: appURL.appendingPathComponent("Contents/PlugIns/Resources.bundle", isDirectory: true),
            bundleID: bundleHelperID
        )
        let app = AppRecord(
            id: appURL.path,
            name: "Fixture",
            bundleID: installedID,
            url: appURL,
            version: "1",
            modified: nil,
            bytes: 0
        )

        let results = RemainingScanner.scan(
            installedApps: [app],
            home: home,
            runningBundleIDs: [runningID],
            applicationURLResolver: { $0 == elsewhereID ? URL(fileURLWithPath: "/Volumes/Elsewhere/App.app") : nil }
        )

        XCTAssertEqual(results.map(\.bundleID), [orphanID])
    }

    func testAppLeftoverAppearsOnlyAfterOwnedApplicationIsRemoved() throws {
        let bundleID = "com.example.removed"
        try createCandidate("Library/Caches/\(bundleID)", isFile: false, bytes: 3)
        let appURL = fixtureRoot.appendingPathComponent("Applications/Owned.app", isDirectory: true)
        try makeApplication(at: appURL, bundleID: bundleID)
        let installed = AppScanner.scan(roots: [fixtureRoot.appendingPathComponent("Applications")])

        XCTAssertTrue(RemainingScanner.scan(
            installedApps: installed,
            home: home,
            runningBundleIDs: [],
            applicationURLResolver: { _ in nil }
        ).isEmpty)

        try FileManager.default.removeItem(at: appURL)

        XCTAssertEqual(RemainingScanner.scan(
            installedApps: [],
            home: home,
            runningBundleIDs: [],
            applicationURLResolver: { _ in nil }
        ).map(\.bundleID), [bundleID])
    }

    func testTrashRejectsDuplicateForgedOutsideAndNewlyOwnedSelections() throws {
        let bundleID = "com.example.safe"
        let candidateURL = home.appendingPathComponent("Library/Caches/\(bundleID)", isDirectory: true)
        try createCandidate("Library/Caches/\(bundleID)", isFile: false, bytes: 4)
        let candidate = try XCTUnwrap(scan().first)

        XCTAssertThrowsError(try move([candidate, candidate]))

        let forged = RemainingFile(
            id: candidate.id,
            url: candidate.url,
            bundleID: "com.example.forged",
            category: candidate.category,
            bytes: candidate.bytes,
            reason: candidate.reason
        )
        XCTAssertThrowsError(try move([forged]))

        let outsideURL = fixtureRoot.appendingPathComponent("com.example.outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        let outside = RemainingFile(
            id: outsideURL.path,
            url: outsideURL,
            bundleID: "com.example.outside",
            category: "Caches",
            bytes: 0,
            reason: "Possible leftover"
        )
        XCTAssertThrowsError(try move([outside]))

        let ownerURL = fixtureRoot.appendingPathComponent("Applications/Owner.app", isDirectory: true)
        try makeApplication(at: ownerURL, bundleID: bundleID)
        let owner = try XCTUnwrap(AppScanner.scan(roots: [fixtureRoot.appendingPathComponent("Applications")]).first)
        XCTAssertThrowsError(try move([candidate], installedApps: [owner]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    func testTrashRejectsCandidateChangedAfterValidation() throws {
        let bundleID = "com.example.changed"
        let candidateURL = home.appendingPathComponent("Library/Caches/\(bundleID)", isDirectory: true)
        try createCandidate("Library/Caches/\(bundleID)", isFile: false, bytes: 4)
        let candidate = try XCTUnwrap(scan().first)

        XCTAssertThrowsError(try move([candidate], beforeMove: { _ in
            try Data([9]).write(to: candidateURL.appendingPathComponent("changed"))
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    func testTrashRejectsSameSizeReplacementSinceInitialScan() throws {
        let bundleID = "com.example.replaced"
        let candidateURL = home.appendingPathComponent("Library/Preferences/\(bundleID).plist")
        try createCandidate("Library/Preferences/\(bundleID).plist", isFile: true, bytes: 4)
        let candidate = try XCTUnwrap(scan().first)

        try FileManager.default.removeItem(at: candidateURL)
        try Data(repeating: 2, count: 4).write(to: candidateURL)

        XCTAssertThrowsError(try move([candidate]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    func testTrashRefreshesApplicationRootsBeforeRevalidatingOwnership() throws {
        let bundleID = "com.example.newly-installed"
        let candidateURL = home.appendingPathComponent("Library/Caches/\(bundleID)", isDirectory: true)
        try createCandidate("Library/Caches/\(bundleID)", isFile: false, bytes: 4)
        let candidate = try XCTUnwrap(scan().first)
        let applications = fixtureRoot.appendingPathComponent("Applications", isDirectory: true)
        try makeApplication(at: applications.appendingPathComponent("New.app"), bundleID: bundleID)

        XCTAssertThrowsError(try move([candidate], applicationScanRoots: [applications]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    func testTrashRechecksOwnershipImmediatelyBeforeEachMove() throws {
        let bundleID = "com.example.installed-during-review"
        let candidateURL = home.appendingPathComponent("Library/Caches/\(bundleID)", isDirectory: true)
        try createCandidate("Library/Caches/\(bundleID)", isFile: false, bytes: 4)
        let candidate = try XCTUnwrap(scan().first)
        let applications = fixtureRoot.appendingPathComponent("Applications", isDirectory: true)

        XCTAssertThrowsError(try move(
            [candidate],
            applicationScanRoots: [applications],
            beforeMove: { _ in
                try self.makeApplication(
                    at: applications.appendingPathComponent("JustInstalled.app"),
                    bundleID: bundleID
                )
            }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
    }

    func testMoveToTrashUsesRealTrashAndReturnsRecoverableDestination() throws {
        let bundleID = "com.example.realtrash.\(UUID().uuidString.lowercased())"
        let original = home.appendingPathComponent("Library/Logs/\(bundleID)", isDirectory: true)
        try createCandidate("Library/Logs/\(bundleID)", isFile: false, bytes: 6)
        let candidate = try XCTUnwrap(scan().first)
        var trashedURL: URL?
        defer {
            if let trashedURL, FileManager.default.fileExists(atPath: trashedURL.path) {
                try? FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: trashedURL, to: original)
            }
        }

        let moved = try move([candidate])
        trashedURL = try XCTUnwrap(moved.first)

        XCTAssertEqual(moved.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL!.path))
    }

    private func scan() -> [RemainingFile] {
        RemainingScanner.scan(
            installedApps: [],
            home: home,
            runningBundleIDs: [],
            applicationURLResolver: { _ in nil }
        )
    }

    private func move(
        _ files: [RemainingFile],
        installedApps: [AppRecord] = [],
        applicationScanRoots: [URL] = [],
        beforeMove: ((URL) throws -> Void)? = nil
    ) throws -> [URL] {
        try RemainingTrashService.moveToTrash(
            files,
            installedApps: installedApps,
            home: home,
            runningBundleIDsProvider: { [] },
            applicationURLResolver: { _ in nil },
            applicationScanRoots: applicationScanRoots,
            beforeMove: beforeMove
        )
    }

    private func createCandidate(_ relativePath: String, isFile: Bool, bytes: Int) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isFile {
            try Data(repeating: 1, count: bytes).write(to: url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url.appendingPathComponent("payload"))
        }
    }

    private func makeApplication(at url: URL, bundleID: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID],
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
