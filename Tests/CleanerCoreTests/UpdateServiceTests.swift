import Foundation
import XCTest
@testable import CleanerCore

final class UpdateServiceTests: XCTestCase {
    func testParsesSparkleAppcastFieldsWithoutResolvingExternalEntities() throws {
        let data = Data("""
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item>
            <link>/releases/2</link>
            <sparkle:version>200</sparkle:version>
            <sparkle:shortVersionString>2.0-beta.2</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
            <sparkle:maximumSystemVersion>15.9.9</sparkle:maximumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url="https://downloads.example.com/App.zip" sparkle:os="macos" />
          </item></channel>
        </rss>
        """.utf8)

        let items = try UpdateParsers.parseAppcast(
            data,
            baseURL: URL(string: "https://updates.example.com/appcast.xml")!
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].version, "200")
        XCTAssertEqual(items[0].displayVersion, "2.0-beta.2")
        XCTAssertEqual(items[0].minimumSystemVersion, "14.0.0")
        XCTAssertEqual(items[0].maximumSystemVersion, "15.9.9")
        XCTAssertEqual(items[0].hardwareRequirements, ["arm64"])
        XCTAssertEqual(items[0].operatingSystem, "macos")
        XCTAssertEqual(items[0].actionURL?.absoluteString, "https://updates.example.com/releases/2")
    }

    func testRejectsMalformedAndEntityBearingAppcasts() {
        XCTAssertThrowsError(try UpdateParsers.parseAppcast(Data("<rss><item>".utf8), baseURL: nil))
        let entityDocument = Data("""
        <?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]>
        <rss><channel><item><title>&x;</title></item></channel></rss>
        """.utf8)
        XCTAssertThrowsError(try UpdateParsers.parseAppcast(entityDocument, baseURL: nil))
    }

    func testVersionComparisonHandlesPrereleasesAndNumericComponents() {
        XCTAssertEqual(UpdateService.compareVersions("2.0", "2.0-beta.9"), .orderedDescending)
        XCTAssertEqual(UpdateService.compareVersions("2.0-beta.10", "2.0-beta.2"), .orderedDescending)
        XCTAssertEqual(UpdateService.compareVersions("1.10", "1.9.9"), .orderedDescending)
        XCTAssertEqual(UpdateService.compareVersions("1.0.0", "1"), .orderedSame)
        XCTAssertEqual(UpdateService.compareVersions("v3.0+45", "3.0"), .orderedSame)
    }

    func testSparkleCheckFindsNewestCompatibleUpdate() async throws {
        let app = try makeApp(version: "1.0", plist: ["SUFeedURL": "https://updates.example.com/feed.xml"])
        let client = StubHTTPClient(responses: [
            "https://updates.example.com/feed.xml": .success(.ok(Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
              <item><sparkle:version>3.0</sparkle:version><sparkle:minimumSystemVersion>16.0.0</sparkle:minimumSystemVersion><link>https://example.com/3</link></item>
              <item><sparkle:version>2.0</sparkle:version><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements><enclosure url="https://example.com/2.zip" sparkle:os="macos" /></item>
            </channel></rss>
            """.utf8)))
        ])
        let service = UpdateService(
            client: client,
            currentOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0),
            architecture: "arm64"
        )

        let result = await service.check(app)

        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertEqual(result.latestVersion, "2.0")
        XCTAssertEqual(result.actionURL?.absoluteString, "https://example.com/2.zip")
    }

    func testSparkleCheckReportsUnsupportedWhenOnlyNewerReleaseCannotRun() async throws {
        let app = try makeApp(version: "1.0", plist: ["SUFeedURL": "https://updates.example.com/feed.xml"])
        let client = StubHTTPClient(responses: [
            "https://updates.example.com/feed.xml": .success(.ok(Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
              <sparkle:version>2.0</sparkle:version><sparkle:minimumSystemVersion>99.0.0</sparkle:minimumSystemVersion>
              <link>https://example.com/2</link>
            </item></channel></rss>
            """.utf8)))
        ])

        let result = await UpdateService(client: client, currentOS: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0), architecture: "arm64").check(app)

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.latestVersion, "2.0")
        XCTAssertNil(result.actionURL)
    }

    func testSparkleDefaultCheckIgnoresPrereleaseChannels() async throws {
        let app = try makeApp(version: "1.0", plist: ["SUFeedURL": "https://updates.example.com/feed.xml"])
        let client = StubHTTPClient(responses: [
            "https://updates.example.com/feed.xml": .success(.ok(Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
              <item><sparkle:version>9.0-beta</sparkle:version><sparkle:channel>beta</sparkle:channel><link>https://example.com/beta</link></item>
              <item><sparkle:version>1.0</sparkle:version><link>https://example.com/stable</link></item>
            </channel></rss>
            """.utf8)))
        ])

        let result = await UpdateService(client: client).check(app)

        XCTAssertEqual(result.status, .current)
        XCTAssertEqual(result.latestVersion, "1.0")
    }

    func testCurrentStatusDoesNotOfferOlderAppcastRelease() async throws {
        let app = try makeApp(version: "2.0", plist: ["SUFeedURL": "https://updates.example.com/feed.xml"])
        let client = StubHTTPClient(responses: [
            "https://updates.example.com/feed.xml": .success(.ok(Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
              <sparkle:version>1.9.9</sparkle:version><link>https://example.com/old</link>
            </item></channel></rss>
            """.utf8)))
        ])

        let result = await UpdateService(client: client).check(app)

        XCTAssertEqual(result.status, .current)
        XCTAssertEqual(result.latestVersion, "1.9.9")
        XCTAssertNil(result.actionURL)
    }

    func testSparkleUsesBundleBuildVersionWhenDisplayVersionIsUnchanged() async throws {
        let app = try makeApp(
            version: "2.0",
            plist: ["SUFeedURL": "https://updates.example.com/feed.xml", "CFBundleVersion": "100"]
        )
        let client = StubHTTPClient(responses: [
            "https://updates.example.com/feed.xml": .success(.ok(Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
              <sparkle:version>101</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString>
              <link>https://example.com/build-101</link>
            </item></channel></rss>
            """.utf8)))
        ])

        let result = await UpdateService(client: client).check(app)

        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertEqual(result.latestVersion, "2.0")
    }

    func testAppStoreReceiptUsesExactBundleMatch() async throws {
        let app = try makeApp(version: "1.0", plist: [:], hasReceipt: true)
        let lookupURL = "https://itunes.apple.com/lookup?bundleId=com.example.fixture&entity=macSoftware"
        let client = StubHTTPClient(responses: [lookupURL: .success(.ok(Data("""
        {"resultCount":2,"results":[
          {"bundleId":"com.example.someone-else","version":"9.0","trackViewUrl":"https://apps.apple.com/app/id1"},
          {"kind":"mac-software","bundleId":"com.example.fixture","version":"1.2","trackViewUrl":"https://apps.apple.com/app/id2"}
        ]}
        """.utf8)))])

        let result = await UpdateService(client: client).check(app)

        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertEqual(result.latestVersion, "1.2")
        XCTAssertEqual(result.actionURL?.absoluteString, "https://apps.apple.com/app/id2")
    }

    func testAppStoreParserRejectsMobileVersionEvenWithMacSupportedDevice() throws {
        let payload = Data(#"{"results":[{"kind":"software","bundleId":"com.example.fixture","version":"19.7","supportedDevices":["MacDesktop-MacDesktop","iPhone"],"trackViewUrl":"https://apps.apple.com/app/id1"}]}"#.utf8)
        XCTAssertNil(try UpdateParsers.parseAppStoreLookup(payload,expectedBundleID:"com.example.fixture"))
    }

    func testAppStoreParserRejectsWrongBundleMatch() throws {
        let data = Data("""
        {"resultCount":1,"results":[{"bundleId":"com.example.other","version":"2.0","trackViewUrl":"https://apps.apple.com/app/id1"}]}
        """.utf8)
        XCTAssertNil(try UpdateParsers.parseAppStoreLookup(data, expectedBundleID: "com.example.fixture"))
    }

    func testAppStoreMinimumOSPreventsIncompatibleSuggestion() async throws {
        let app = try makeApp(version: "1.0", plist: [:], hasReceipt: true)
        let lookupURL = "https://itunes.apple.com/lookup?bundleId=com.example.fixture&entity=macSoftware"
        let client = StubHTTPClient(responses: [lookupURL: .success(.ok(Data("""
        {"resultCount":1,"results":[
          {"kind":"mac-software","bundleId":"com.example.fixture","version":"2.0","minimumOsVersion":"99.0","trackViewUrl":"https://apps.apple.com/app/id2"}
        ]}
        """.utf8)))])

        let result = await UpdateService(
            client: client,
            currentOS: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        ).check(app)

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.latestVersion, "2.0")
        XCTAssertNil(result.actionURL)
    }

    func testNetworkFailureAndUnknownInstalledVersionAreExplicitFailures() async throws {
        let networkApp = try makeApp(version: "1.0", plist: ["SUFeedURL": "https://updates.example.com/feed.xml"])
        let unknownApp = try makeApp(version: "", plist: ["SUFeedURL": "https://updates.example.com/feed.xml"])
        let client = StubHTTPClient(responses: [
            "https://updates.example.com/feed.xml": .failure(TestError.offline)
        ])
        let service = UpdateService(client: client)

        let networkResult = await service.check(networkApp)
        let unknownResult = await service.check(unknownApp)

        XCTAssertEqual(networkResult.status, .failed)
        XCTAssertTrue(networkResult.detail.localizedCaseInsensitiveContains("offline"))
        XCTAssertEqual(unknownResult.status, .failed)
        XCTAssertTrue(unknownResult.detail.localizedCaseInsensitiveContains("unknown"))
    }

    func testUnsafeFeedURLIsRejectedWithoutNetworkRequest() async throws {
        let client = StubHTTPClient(responses: [:])
        for feedURL in [
            "http://127.0.0.1/feed.xml",
            "https://127.1/feed.xml",
            "https://[::1]/feed.xml",
            "https://updates.local/feed.xml",
        ] {
            let app = try makeApp(version: "1", plist: ["SUFeedURL": feedURL])
            let result = await UpdateService(client: client).check(app)
            XCTAssertEqual(result.status, .failed)
            XCTAssertTrue(result.detail.contains("HTTPS"))
        }
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testBatchCheckPreservesInputOrder() async throws {
        let first = try makeApp(name: "First", version: "1", plist: [:])
        let second = try makeApp(name: "Second", version: "1", plist: [:])
        let results = await UpdateService(client: StubHTTPClient(responses: [:]), maxConcurrentChecks: 2)
            .check(apps: [first, second])
        XCTAssertEqual(results.map(\.appName), ["First", "Second"])
        XCTAssertEqual(results.map(\.status), [.unsupported, .unsupported])
    }

    func testElectronGenericProviderParsesQuotedYAMLAndSelectsHostArchitecture() async throws {
        let app = try makeApp(
            version: "1.0",
            plist: [:],
            electronUpdateYAML: "provider: \"generic\"\nurl: 'https://updates.example.com/releases/'\n"
        )
        let client = StubHTTPClient(responses: [
            "https://updates.example.com/releases/latest-mac.yml": .success(.ok(Data("""
            version: "1.2.0"
            files:
              - url: "Fixture-1.2.0-x64.zip"
              - url: 'Fixture-1.2.0-arm64.zip'
            """.utf8)))
        ])

        let result = await UpdateService(client: client, architecture: "arm64").check(app)

        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertEqual(result.latestVersion, "1.2.0")
        XCTAssertEqual(result.actionURL?.absoluteString, "https://updates.example.com/releases/Fixture-1.2.0-arm64.zip")
    }

    func testElectronGenericProviderReportsUnsupportedForWrongArchitecture() async throws {
        let app = try makeApp(
            version: "1.0",
            plist: [:],
            electronUpdateYAML: "provider: generic\nurl: https://updates.example.com/releases\n"
        )
        let client = StubHTTPClient(responses: [
            "https://updates.example.com/releases/latest-mac.yml": .success(.ok(Data("""
            version: 2.0
            files:
              - url: Fixture-2.0-x64.zip
            """.utf8)))
        ])

        let result = await UpdateService(client: client, architecture: "arm64").check(app)

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.latestVersion, "2.0")
        XCTAssertNil(result.actionURL)
    }

    func testElectronRejectsMaliciousOrUnknownProviderWithoutRequest() async throws {
        let malicious = try makeApp(
            version: "1",
            plist: [:],
            electronUpdateYAML: "provider: generic\nurl: https://127.1/releases\n"
        )
        let unknown = try makeApp(
            version: "1",
            plist: [:],
            electronUpdateYAML: "provider: custom-provider\nurl: https://updates.example.com\n"
        )
        let client = StubHTTPClient(responses: [:])
        let service = UpdateService(client: client)

        let maliciousResult = await service.check(malicious)
        let unknownResult = await service.check(unknown)
        XCTAssertEqual(maliciousResult.status, .failed)
        XCTAssertEqual(unknownResult.status, .unsupported)
        let requestCount = await client.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testElectronGitHubProviderUsesExactRepositoryReleaseAPI() async throws {
        let app = try makeApp(
            version: "1.0",
            plist: [:],
            electronUpdateYAML: "provider: github\nowner: 'example-org'\nrepo: \"fixture-app\"\n"
        )
        let client = StubHTTPClient(responses: [
            "https://api.github.com/repos/example-org/fixture-app/releases/latest": .success(.ok(Data("""
            {"tag_name":"v1.4.0","html_url":"https://github.com/example-org/fixture-app/releases/tag/v1.4.0","assets":[
              {"name":"latest-mac.yml","browser_download_url":"https://github.com/example-org/fixture-app/releases/download/v1.4.0/latest-mac.yml"}
            ]}
            """.utf8))),
            "https://github.com/example-org/fixture-app/releases/download/v1.4.0/latest-mac.yml": .success(.ok(Data("""
            version: 1.4.0
            files:
              - url: https://github.com/example-org/fixture-app/releases/download/v1.4.0/Fixture-1.4.0-arm64.zip
            """.utf8)))
        ])

        let result = await UpdateService(client: client).check(app)

        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertEqual(result.latestVersion, "1.4.0")
        XCTAssertEqual(result.actionURL?.host, "github.com")
    }

    func testElectronGitHubWindowsOnlyReleaseIsUnsupported() async throws {
        let app = try makeApp(
            version: "1.0",
            plist: [:],
            electronUpdateYAML: "provider: github\nowner: example-org\nrepo: fixture-app\n"
        )
        let client = StubHTTPClient(responses: [
            "https://api.github.com/repos/example-org/fixture-app/releases/latest": .success(.ok(Data("""
            {"tag_name":"v9.0","html_url":"https://github.com/example-org/fixture-app/releases/tag/v9.0","assets":[
              {"name":"latest.yml","browser_download_url":"https://github.com/example/latest.yml"}
            ]}
            """.utf8)))
        ])

        let result = await UpdateService(client: client).check(app)

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertTrue(result.detail.contains("latest-mac.yml"))
    }

    private func makeApp(
        name: String = "Fixture",
        version: String,
        plist extraPlist: [String: Any],
        hasReceipt: Bool = false,
        electronUpdateYAML: String? = nil
    ) throws -> AppRecord {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateServiceTests-\(UUID().uuidString).app", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = extraPlist
        plist["CFBundleIdentifier"] = "com.example.fixture"
        plist["CFBundleShortVersionString"] = version
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if hasReceipt {
            let receipt = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data([1]).write(to: receipt.appendingPathComponent("receipt"))
        }
        if let electronUpdateYAML {
            let resources = contents.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try Data(electronUpdateYAML.utf8).write(to: resources.appendingPathComponent("app-update.yml"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AppRecord(id: root.path, name: name, bundleID: "com.example.fixture", url: root, version: version, modified: nil, bytes: 0)
    }
}

private enum TestError: Error, LocalizedError {
    case offline
    var errorDescription: String? { "Offline test failure" }
}

private actor StubHTTPClient: UpdateHTTPClient {
    private let responses: [String: Result<UpdateHTTPResponse, Error>]
    private(set) var requestCount = 0

    init(responses: [String: Result<UpdateHTTPResponse, Error>]) {
        self.responses = responses
    }

    func get(_ url: URL, timeout: TimeInterval, maximumBytes: Int) async throws -> UpdateHTTPResponse {
        requestCount += 1
        guard let response = responses[url.absoluteString] else { throw TestError.offline }
        return try response.get()
    }
}

private extension UpdateHTTPResponse {
    static func ok(_ data: Data) -> UpdateHTTPResponse {
        UpdateHTTPResponse(data: data, statusCode: 200, finalURL: nil)
    }
}
