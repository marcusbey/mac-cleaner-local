import Foundation
import XCTest
@testable import CleanerCore

final class AppScannerTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanerCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    func testScanFindsNestedApplicationWithoutDescendingIntoItsBundle() throws {
        let applications = fixtureRoot.appendingPathComponent("Applications", isDirectory: true)
        let outerApp = applications.appendingPathComponent("Utilities/Example.app", isDirectory: true)
        try makeApplication(
            at: outerApp,
            bundleID: "com.example.cleaner-fixture",
            name: "Fixture Cleaner",
            version: "2.4.1",
            payload: Data(repeating: 0x2A, count: 37)
        )
        try makeApplication(
            at: outerApp.appendingPathComponent("Contents/PlugIns/Hidden.app", isDirectory: true),
            bundleID: "com.example.hidden",
            name: "Hidden Helper",
            version: "1.0",
            payload: Data(repeating: 0x1, count: 11)
        )

        let records = AppScanner.scan(roots: [applications])

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, outerApp.path)
        XCTAssertEqual(record.name, "Fixture Cleaner")
        XCTAssertEqual(record.bundleID, "com.example.cleaner-fixture")
        XCTAssertEqual(record.version, "2.4.1")
        XCTAssertGreaterThanOrEqual(record.bytes, 37)
        XCTAssertNotNil(record.modified)
    }

    func testEmptyDisplayNameFallsBackToBundleFilename() throws {
        let applications = fixtureRoot.appendingPathComponent("Applications", isDirectory: true)
        let app = applications.appendingPathComponent("Visible Name.app", isDirectory: true)
        try makeApplication(at: app, bundleID: "com.example.empty", name: "", version: "1", payload: Data([1]))
        XCTAssertEqual(AppScanner.scan(roots: [applications]).first?.name, "Visible Name")
    }

    func testScanSkipsSymbolicLinks() throws {
        let applications = fixtureRoot.appendingPathComponent("Applications", isDirectory: true)
        let realApp = fixtureRoot.appendingPathComponent("Elsewhere/Linked.app", isDirectory: true)
        try makeApplication(
            at: realApp,
            bundleID: "com.example.linked",
            name: "Linked",
            version: "1",
            payload: Data([1])
        )
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: applications.appendingPathComponent("Linked.app"),
            withDestinationURL: realApp
        )

        XCTAssertTrue(AppScanner.scan(roots: [applications]).isEmpty)
    }

    func testRelatedFilesUseOnlyExactBundleIdentifierPaths() throws {
        let home = fixtureRoot.appendingPathComponent("Home", isDirectory: true)
        let bundleID = "com.example.fixture"
        let exactPaths = [
            "Library/Caches/\(bundleID)",
            "Library/Preferences/\(bundleID).plist",
            "Library/Application Support/\(bundleID)",
            "Library/Saved Application State/\(bundleID).savedState",
            "Library/Logs/\(bundleID)",
            "Library/Containers/\(bundleID)",
            "Library/Application Scripts/\(bundleID)",
        ]
        let nearMatchPaths = [
            "Library/Caches/\(bundleID).helper",
            "Library/Preferences/\(bundleID).helper.plist",
            "Library/Application Support/Fixture",
            "Library/Group Containers/\(bundleID)",
        ]

        for relativePath in exactPaths + nearMatchPaths {
            let url = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if url.pathExtension == "plist" {
                try Data([1, 2, 3]).write(to: url)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: url.appendingPathComponent("payload"))
            }
        }

        let app = AppRecord(
            id: "/Applications/Fixture.app",
            name: "Fixture",
            bundleID: bundleID,
            url: URL(fileURLWithPath: "/Applications/Fixture.app"),
            version: "1",
            modified: nil,
            bytes: 0
        )
        let related = AppScanner.relatedFiles(for: app, home: home)

        XCTAssertEqual(Set(related.map(\.url.path)), Set(exactPaths.map { home.appendingPathComponent($0).path }))
        XCTAssertEqual(Set(related.map(\.category)), Set(["Caches", "Preferences", "Application Support", "Saved Application State", "Logs", "Container", "Application Scripts"]))
        XCTAssertTrue(related.allSatisfy { $0.category == "Container" ? $0.bytes >= 3 : $0.bytes == 3 })
    }

    func testDirectorySizeIgnoresSymbolicLinkTargets() throws {
        let directory = fixtureRoot.appendingPathComponent("Size", isDirectory: true)
        let external = fixtureRoot.appendingPathComponent("external.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 7).write(to: directory.appendingPathComponent("local.bin"))
        try Data(repeating: 0, count: 41).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked.bin"),
            withDestinationURL: external
        )

        XCTAssertEqual(AppScanner.directorySize(directory), 7)
    }

    func testRelatedFilesRejectBundleIdentifierPathTraversal() throws {
        let home = fixtureRoot.appendingPathComponent("Home", isDirectory: true)
        let escaped = fixtureRoot.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)
        let app = AppRecord(
            id: "/Applications/Fixture.app",
            name: "Fixture",
            bundleID: "../../../escaped",
            url: URL(fileURLWithPath: "/Applications/Fixture.app"),
            version: "1",
            modified: nil,
            bytes: 0
        )

        XCTAssertTrue(AppScanner.relatedFiles(for: app, home: home).isEmpty)
    }

    func testBundleIdentifierReadsCurrentMetadataFromDisk() throws {
        let appURL = fixtureRoot.appendingPathComponent("Current.app", isDirectory: true)
        try makeApplication(
            at: appURL,
            bundleID: "com.example.current",
            name: "Current",
            version: "1",
            payload: Data()
        )

        XCTAssertEqual(AppScanner.bundleIdentifier(at: appURL), "com.example.current")
    }

    private func makeApplication(
        at url: URL,
        bundleID: String,
        name: String,
        version: String,
        payload: Data
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleDisplayName": name,
            "CFBundleShortVersionString": version,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        try payload.write(to: resources.appendingPathComponent("payload.bin"))
    }
}
