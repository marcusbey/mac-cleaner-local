import Foundation
import Darwin

public enum UpdateStatus: String, Sendable, Codable, CaseIterable {
    case updateAvailable
    case current
    case unsupported
    case failed
}

public struct UpdateResult: Identifiable, Sendable, Equatable {
    public var id: String { appID }
    public let appID: String
    public let appName: String
    public let installedVersion: String
    public let latestVersion: String?
    public let status: UpdateStatus
    public let detail: String
    public let actionURL: URL?

    public init(
        appID: String,
        appName: String,
        installedVersion: String,
        latestVersion: String?,
        status: UpdateStatus,
        detail: String,
        actionURL: URL?
    ) {
        self.appID = appID
        self.appName = appName
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.status = status
        self.detail = detail
        self.actionURL = actionURL
    }
}

public struct UpdateHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let finalURL: URL?

    public init(data: Data, statusCode: Int, finalURL: URL?) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

public protocol UpdateHTTPClient: Sendable {
    func get(_ url: URL, timeout: TimeInterval, maximumBytes: Int) async throws -> UpdateHTTPResponse
}

public enum UpdateServiceError: Error, LocalizedError, Sendable {
    case unsafeURL
    case invalidResponse
    case httpStatus(Int)
    case payloadTooLarge
    case malformedPayload

    public var errorDescription: String? {
        switch self {
        case .unsafeURL: return "The update source must be a public HTTPS URL."
        case .invalidResponse: return "The update server returned an invalid response."
        case .httpStatus(let status): return "The update server returned HTTP \(status)."
        case .payloadTooLarge: return "The update response exceeded the allowed size."
        case .malformedPayload: return "The update server returned malformed update data."
        }
    }
}

public final class URLSessionUpdateHTTPClient: NSObject, UpdateHTTPClient, @unchecked Sendable {
    public override init() {}

    public func get(_ url: URL, timeout: TimeInterval, maximumBytes: Int) async throws -> UpdateHTTPResponse {
        guard SecureUpdateURL.isPublicNetworkTarget(url) else { throw UpdateServiceError.unsafeURL }
        let delegate = BoundedDataDelegate(maximumBytes: maximumBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/rss+xml, application/xml, application/json", forHTTPHeaderField: "Accept")
        return try await delegate.perform(request, in: session)
    }
}

private final class BoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<UpdateHTTPResponse, Error>?
    private var task: URLSessionDataTask?
    private var completed = false
    private var cancelled = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func perform(_ request: URLRequest, in session: URLSession) async throws -> UpdateHTTPResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                self.continuation = continuation
                self.task = task
                let shouldCancel = cancelled
                lock.unlock()
                if shouldCancel {
                    task.cancel()
                    finish(.failure(CancellationError()))
                } else {
                    task.resume()
                }
            }
        }, onCancel: { [self] in
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
            finish(.failure(CancellationError()))
        })
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(SecureUpdateURL.isPublicNetworkTarget) == true ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url,
              SecureUpdateURL.isAllowed(finalURL) else {
            completionHandler(.cancel)
            finish(.failure(UpdateServiceError.invalidResponse))
            return
        }
        if let expectedLength = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           expectedLength > maximumBytes {
            completionHandler(.cancel)
            finish(.failure(UpdateServiceError.payloadTooLarge))
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incomingData: Data) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        if data.count > maximumBytes - incomingData.count {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(UpdateServiceError.payloadTooLarge))
            return
        }
        data.append(incomingData)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let data = self.data
        lock.unlock()
        guard let response else {
            finish(.failure(UpdateServiceError.invalidResponse))
            return
        }
        finish(.success(UpdateHTTPResponse(data: data, statusCode: response.statusCode, finalURL: response.url)))
    }

    private func finish(_ result: Result<UpdateHTTPResponse, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

public struct SparkleAppcastItem: Sendable, Equatable {
    public let version: String
    public let displayVersion: String
    public let minimumSystemVersion: String?
    public let maximumSystemVersion: String?
    public let hardwareRequirements: [String]
    public let operatingSystem: String?
    public let channel: String?
    public let actionURL: URL?

    public init(
        version: String,
        displayVersion: String,
        minimumSystemVersion: String?,
        maximumSystemVersion: String?,
        hardwareRequirements: [String],
        operatingSystem: String?,
        channel: String? = nil,
        actionURL: URL?
    ) {
        self.version = version
        self.displayVersion = displayVersion
        self.minimumSystemVersion = minimumSystemVersion
        self.maximumSystemVersion = maximumSystemVersion
        self.hardwareRequirements = hardwareRequirements
        self.operatingSystem = operatingSystem
        self.channel = channel
        self.actionURL = actionURL
    }
}

public struct AppStoreLookupItem: Sendable, Equatable {
    public let bundleID: String
    public let version: String
    public let actionURL: URL?
    public let minimumSystemVersion: String?

    public init(bundleID: String, version: String, actionURL: URL?, minimumSystemVersion: String? = nil) {
        self.bundleID = bundleID
        self.version = version
        self.actionURL = actionURL
        self.minimumSystemVersion = minimumSystemVersion
    }
}

public struct ElectronUpdateConfiguration: Sendable, Equatable {
    public let provider: String
    public let url: String?
    public let owner: String?
    public let repo: String?
    public let channel: String?

    public init(provider: String, url: String?, owner: String?, repo: String?, channel: String?) {
        self.provider = provider
        self.url = url
        self.owner = owner
        self.repo = repo
        self.channel = channel
    }
}

public struct ElectronUpdateManifest: Sendable, Equatable {
    public let version: String
    public let filePaths: [String]

    public init(version: String, filePaths: [String]) {
        self.version = version
        self.filePaths = filePaths
    }
}

public struct GitHubReleaseItem: Sendable, Equatable {
    public let version: String
    public let actionURL: URL?
    public let assets: [GitHubReleaseAsset]

    public init(version: String, actionURL: URL?, assets: [GitHubReleaseAsset] = []) {
        self.version = version
        self.actionURL = actionURL
        self.assets = assets
    }
}

public struct GitHubReleaseAsset: Sendable, Equatable {
    public let name: String
    public let downloadURL: URL?

    public init(name: String, downloadURL: URL?) {
        self.name = name
        self.downloadURL = downloadURL
    }
}

public enum UpdateParsers {
    public static func parseAppcast(_ data: Data, baseURL: URL?) throws -> [SparkleAppcastItem] {
        guard !containsDocumentType(data) else { throw UpdateServiceError.malformedPayload }
        let delegate = AppcastParserDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.depth == 0 else { throw parser.parserError ?? UpdateServiceError.malformedPayload }
        return delegate.items
    }

    public static func parseAppStoreLookup(_ data: Data, expectedBundleID: String) throws -> AppStoreLookupItem? {
        struct Envelope: Decodable { let results: [Item] }
        struct Item: Decodable {
            let bundleId: String?
            let kind: String?
            let version: String?
            let trackViewUrl: String?
            let minimumOsVersion: String?
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw UpdateServiceError.malformedPayload
        }
        guard let match = envelope.results.first(where: { $0.bundleId == expectedBundleID && $0.kind == "mac-software" }),
              let version = nonempty(match.version) else {
            return nil
        }
        let actionURL = match.trackViewUrl.flatMap(URL.init(string:)).flatMap { SecureUpdateURL.isAllowed($0) ? $0 : nil }
        return AppStoreLookupItem(
            bundleID: expectedBundleID,
            version: version,
            actionURL: actionURL,
            minimumSystemVersion: nonempty(match.minimumOsVersion)
        )
    }

    public static func parseElectronUpdateConfiguration(_ data: Data) throws -> ElectronUpdateConfiguration {
        let values = try SimpleYAML.topLevelScalars(data)
        guard let provider = nonempty(values["provider"])?.lowercased() else {
            throw UpdateServiceError.malformedPayload
        }
        return ElectronUpdateConfiguration(
            provider: provider,
            url: nonempty(values["url"]),
            owner: nonempty(values["owner"]),
            repo: nonempty(values["repo"]),
            channel: nonempty(values["channel"])
        )
    }

    public static func parseElectronUpdateManifest(_ data: Data) throws -> ElectronUpdateManifest {
        let values = try SimpleYAML.topLevelScalars(data)
        guard let version = nonempty(values["version"]) else { throw UpdateServiceError.malformedPayload }
        var paths = try SimpleYAML.listValues(data, key: "files", itemKey: "url")
        if paths.isEmpty, let legacyPath = nonempty(values["path"]) { paths = [legacyPath] }
        return ElectronUpdateManifest(version: version, filePaths: paths)
    }

    public static func parseGitHubRelease(_ data: Data) throws -> GitHubReleaseItem {
        struct Asset: Decodable { let name: String; let browser_download_url: String? }
        struct Release: Decodable { let tag_name: String; let html_url: String?; let assets: [Asset]? }
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw UpdateServiceError.malformedPayload
        }
        var version = release.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first?.lowercased() == "v", version.dropFirst().first?.isNumber == true { version.removeFirst() }
        guard !version.isEmpty else { throw UpdateServiceError.malformedPayload }
        let actionURL = release.html_url.flatMap(URL.init(string:)).flatMap { SecureUpdateURL.isAllowed($0) ? $0 : nil }
        let assets = (release.assets ?? []).map { asset in
            GitHubReleaseAsset(
                name: asset.name,
                downloadURL: asset.browser_download_url.flatMap(URL.init(string:)).flatMap { SecureUpdateURL.isAllowed($0) ? $0 : nil }
            )
        }
        return GitHubReleaseItem(version: version, actionURL: actionURL, assets: assets)
    }

    private static func containsDocumentType(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8)?.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil
    }

    fileprivate static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private enum SimpleYAML {
    static func topLevelScalars(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { throw UpdateServiceError.malformedPayload }
        var output: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard indentation(of: line) == 0,
                  let pair = keyValue(line),
                  !pair.value.isEmpty else { continue }
            output[pair.key.lowercased()] = try scalar(pair.value)
        }
        return output
    }

    static func listValues(_ data: Data, key: String, itemKey: String) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { throw UpdateServiceError.malformedPayload }
        var inList = false
        var listIndent = 0
        var output: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let indent = indentation(of: line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent == 0 {
                inList = trimmed.lowercased() == "\(key.lowercased()):"
                listIndent = inList ? indent : 0
                continue
            }
            guard inList, indent > listIndent else { continue }
            let candidate = trimmed.hasPrefix("-")
                ? trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                : trimmed
            guard let pair = keyValue(candidate), pair.key.lowercased() == itemKey.lowercased() else { continue }
            output.append(try scalar(pair.value))
        }
        return output.filter { !$0.isEmpty }
    }

    private static func keyValue<S: StringProtocol>(_ line: S) -> (key: String, value: String)? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func scalar(_ rawValue: String) throws -> String {
        let value = stripComment(rawValue).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.hasPrefix("&"), !value.hasPrefix("*"), !value.hasPrefix("!") else {
            throw UpdateServiceError.malformedPayload
        }
        if value.hasPrefix("\"") || value.hasSuffix("\"") {
            guard value.hasPrefix("\""), value.hasSuffix("\""),
                  let data = value.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                throw UpdateServiceError.malformedPayload
            }
            return decoded
        }
        if value.hasPrefix("'") || value.hasSuffix("'") {
            guard value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 else {
                throw UpdateServiceError.malformedPayload
            }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func stripComment(_ value: String) -> String {
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped { escaped = false; continue }
            if character == "\\", doubleQuoted { escaped = true; continue }
            if character == "'", !doubleQuoted { singleQuoted.toggle(); continue }
            if character == "\"", !singleQuoted { doubleQuoted.toggle(); continue }
            if character == "#", !singleQuoted, !doubleQuoted {
                return String(value[..<index])
            }
        }
        return value
    }

    private static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}

private final class AppcastParserDelegate: NSObject, XMLParserDelegate {
    private struct Builder {
        var version: String?
        var displayVersion: String?
        var minimumSystemVersion: String?
        var maximumSystemVersion: String?
        var hardwareRequirements: [String] = []
        var operatingSystem: String?
        var channel: String?
        var link: URL?
        var enclosure: URL?
    }

    let baseURL: URL?
    var items: [SparkleAppcastItem] = []
    var depth = 0
    private var builder: Builder?
    private var currentElement = ""
    private var text = ""

    init(baseURL: URL?) { self.baseURL = baseURL }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        currentElement = elementName.lowercased()
        text = ""
        if currentElement == "item" {
            builder = Builder()
        } else if currentElement == "enclosure", builder != nil {
            let version = value(named: "version", in: attributeDict)
            let displayVersion = value(named: "shortversionstring", in: attributeDict)
            let operatingSystem = value(named: "os", in: attributeDict)
            if let version { builder?.version = version }
            if let displayVersion { builder?.displayVersion = displayVersion }
            if let operatingSystem { builder?.operatingSystem = operatingSystem }
            if let value = attributeDict["url"] {
                builder?.enclosure = resolvedURL(value)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            depth -= 1
            text = ""
        }
        guard var item = builder else { return }
        let name = elementName.lowercased()
        let value = UpdateParsers.nonempty(text)
        switch localName(name) {
        case "version": item.version = value ?? item.version
        case "shortversionstring": item.displayVersion = value ?? item.displayVersion
        case "minimumsystemversion": item.minimumSystemVersion = value
        case "maximumsystemversion": item.maximumSystemVersion = value
        case "hardwarerequirements": item.hardwareRequirements = splitRequirements(value)
        case "channel": item.channel = value
        case "link": item.link = value.flatMap(resolvedURL)
        case "item":
            if let version = UpdateParsers.nonempty(item.version) {
                let display = UpdateParsers.nonempty(item.displayVersion) ?? version
                let action = [item.link, item.enclosure].compactMap { $0 }.first(where: SecureUpdateURL.isAllowed)
                items.append(SparkleAppcastItem(
                    version: version,
                    displayVersion: display,
                    minimumSystemVersion: item.minimumSystemVersion,
                    maximumSystemVersion: item.maximumSystemVersion,
                    hardwareRequirements: item.hardwareRequirements,
                    operatingSystem: item.operatingSystem,
                    channel: item.channel,
                    actionURL: action
                ))
            }
            builder = nil
            return
        default: break
        }
        builder = item
    }

    private func value(named localName: String, in attributes: [String: String]) -> String? {
        attributes.first { key, _ in self.localName(key.lowercased()) == localName }?.value
    }

    private func localName(_ qualifiedName: String) -> String {
        qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName
    }

    private func splitRequirements(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map { $0.lowercased() }
    }

    private func resolvedURL(_ value: String) -> URL? {
        let url = URL(string: value, relativeTo: baseURL)?.absoluteURL
        return url.flatMap { SecureUpdateURL.isAllowed($0) ? $0 : nil }
    }
}

public struct UpdateService: Sendable {
    private static let appcastMaximumBytes = 2 * 1_024 * 1_024
    private static let appStoreMaximumBytes = 1 * 1_024 * 1_024
    private static let electronMaximumBytes = 1 * 1_024 * 1_024
    private static let requestTimeout: TimeInterval = 10

    private let client: any UpdateHTTPClient
    private let currentOS: OperatingSystemVersion
    private let architecture: String
    private let maxConcurrentChecks: Int

    public init(
        client: any UpdateHTTPClient = URLSessionUpdateHTTPClient(),
        currentOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        architecture: String = UpdateService.hostArchitecture,
        maxConcurrentChecks: Int = 4
    ) {
        self.client = client
        self.currentOS = currentOS
        self.architecture = architecture.lowercased()
        self.maxConcurrentChecks = max(1, min(maxConcurrentChecks, 16))
    }

    public func check(_ app: AppRecord) async -> UpdateResult {
        guard let installedVersion = UpdateParsers.nonempty(app.version) else {
            return result(app, latest: nil, status: .failed, detail: "Installed version is unknown.")
        }
        let metadata = bundleMetadata(at: app.url)
        if let feedValue = UpdateParsers.nonempty(metadata?["SUFeedURL"] as? String) {
            guard let feedURL = URL(string: feedValue), SecureUpdateURL.isAllowed(feedURL) else {
                return result(app, latest: nil, status: .failed, detail: UpdateServiceError.unsafeURL.localizedDescription)
            }
            let installedBuildVersion = UpdateParsers.nonempty(metadata?["CFBundleVersion"] as? String)
            return await checkSparkle(
                app,
                installedVersion: installedVersion,
                installedBuildVersion: installedBuildVersion,
                feedURL: feedURL
            )
        }
        if hasAppStoreReceipt(at: app.url) {
            guard !app.bundleID.isEmpty else {
                return result(app, latest: nil, status: .failed, detail: "The App Store receipt has no bundle identifier to look up.")
            }
            return await checkAppStore(app, installedVersion: installedVersion)
        }
        if let configuration = electronConfiguration(at: app.url) {
            switch configuration {
            case .success(let data):
                return await checkElectron(app, installedVersion: installedVersion, configurationData: data)
            case .failure(let error):
                return result(app, latest: nil, status: .failed, detail: "Electron update configuration cannot be read safely: \(error.localizedDescription)")
            }
        }
        return result(app, latest: nil, status: .unsupported, detail: "This app does not advertise a Sparkle feed or contain a Mac App Store receipt.")
    }

    public func check(apps: [AppRecord]) async -> [UpdateResult] {
        guard !apps.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, UpdateResult).self) { group in
            var nextIndex = 0
            var results = Array<UpdateResult?>(repeating: nil, count: apps.count)
            func addNext() {
                guard !Task.isCancelled, nextIndex < apps.count else { return }
                let index = nextIndex
                let app = apps[index]
                nextIndex += 1
                group.addTask { (index, await check(app)) }
            }
            for _ in 0..<min(maxConcurrentChecks, apps.count) { addNext() }
            while let (index, value) = await group.next() {
                results[index] = value
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                addNext()
            }
            return results.compactMap { $0 }
        }
    }

    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        ParsedVersion(lhs).compare(to: ParsedVersion(rhs))
    }

    private func checkSparkle(
        _ app: AppRecord,
        installedVersion: String,
        installedBuildVersion: String?,
        feedURL: URL
    ) async -> UpdateResult {
        do {
            let response = try await client.get(feedURL, timeout: Self.requestTimeout, maximumBytes: Self.appcastMaximumBytes)
            try validate(response, maximumBytes: Self.appcastMaximumBytes)
            let items = try UpdateParsers.parseAppcast(response.data, baseURL: response.finalURL ?? feedURL)
            guard !items.isEmpty else {
                return result(app, latest: nil, status: .failed, detail: "The Sparkle feed contains no recognizable releases.")
            }
            let defaultChannelItems = items.filter { UpdateParsers.nonempty($0.channel) == nil }
            guard !defaultChannelItems.isEmpty else {
                return result(app, latest: nil, status: .unsupported, detail: "The Sparkle feed contains only nondefault update channels.")
            }
            let installedComparisonVersion = installedBuildVersion ?? installedVersion
            let version: (SparkleAppcastItem) -> String = {
                installedBuildVersion == nil ? $0.displayVersion : $0.version
            }
            let overall = newest(defaultChannelItems, version: version)
            let compatible = newest(defaultChannelItems.filter(isCompatible), version: version)
            if let compatible, Self.compareVersions(version(compatible), installedComparisonVersion) == .orderedDescending {
                guard let actionURL = compatible.actionURL else {
                    return result(app, latest: compatible.displayVersion, status: .failed, detail: "A newer release exists, but it has no safe HTTPS release link.")
                }
                return result(app, latest: compatible.displayVersion, status: .updateAvailable, detail: "Source: \(feedURL.host ?? "Sparkle feed"). A newer compatible release is available.", actionURL: actionURL)
            }
            if let overall, Self.compareVersions(version(overall), installedComparisonVersion) == .orderedDescending,
               compatible == nil || Self.compareVersions(version(compatible!), installedComparisonVersion) != .orderedDescending {
                return result(app, latest: overall.displayVersion, status: .unsupported, detail: "A newer release exists, but it does not support this Mac.")
            }
            return result(app, latest: compatible?.displayVersion ?? overall?.displayVersion, status: .current, detail: "Source: \(feedURL.host ?? "Sparkle feed"). No newer compatible release was found.")
        } catch {
            return result(app, latest: nil, status: .failed, detail: "Update check failed: \(error.localizedDescription)")
        }
    }

    private func checkAppStore(_ app: AppRecord, installedVersion: String) async -> UpdateResult {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: app.bundleID),
            URLQueryItem(name: "entity", value: "macSoftware"),
        ]
        guard let url = components.url else {
            return result(app, latest: nil, status: .failed, detail: "The App Store lookup URL could not be created.")
        }
        do {
            let response = try await client.get(url, timeout: Self.requestTimeout, maximumBytes: Self.appStoreMaximumBytes)
            try validate(response, maximumBytes: Self.appStoreMaximumBytes)
            guard let item = try UpdateParsers.parseAppStoreLookup(response.data, expectedBundleID: app.bundleID) else {
                return result(app, latest: nil, status: .unsupported, detail: "The App Store did not return a verified macOS release. Mobile and unified listings can use a different version; check the App Store directly.")
            }
            if Self.compareVersions(item.version, installedVersion) == .orderedDescending {
                if let minimum = item.minimumSystemVersion {
                    let os = "\(currentOS.majorVersion).\(currentOS.minorVersion).\(currentOS.patchVersion)"
                    if Self.compareVersions(os, minimum) == .orderedAscending {
                        return result(app, latest: item.version, status: .unsupported, detail: "Source: App Store catalog comparison (receipt marker present). A newer version requires macOS \(minimum) or later.")
                    }
                }
                guard let actionURL = item.actionURL else {
                    return result(app, latest: item.version, status: .failed, detail: "The App Store reports a newer version but provided no safe HTTPS store link.")
                }
                return result(app, latest: item.version, status: .updateAvailable, detail: "Source: App Store catalog comparison (receipt marker present). A newer version is available.", actionURL: actionURL)
            }
            return result(app, latest: item.version, status: .current, detail: "Source: App Store catalog comparison (receipt marker present). No newer version was found.")
        } catch {
            return result(app, latest: nil, status: .failed, detail: "App Store update check failed: \(error.localizedDescription)")
        }
    }

    private func checkElectron(
        _ app: AppRecord,
        installedVersion: String,
        configurationData: Data
    ) async -> UpdateResult {
        do {
            let configuration = try UpdateParsers.parseElectronUpdateConfiguration(configurationData)
            switch configuration.provider {
            case "generic":
                return await checkElectronGeneric(app, installedVersion: installedVersion, configuration: configuration)
            case "github":
                return await checkElectronGitHub(app, installedVersion: installedVersion, configuration: configuration)
            default:
                return result(app, latest: nil, status: .unsupported, detail: "Electron update provider '\(configuration.provider)' is not supported.")
            }
        } catch {
            return result(app, latest: nil, status: .failed, detail: "Electron update configuration is invalid: \(error.localizedDescription)")
        }
    }

    private func checkElectronGeneric(
        _ app: AppRecord,
        installedVersion: String,
        configuration: ElectronUpdateConfiguration
    ) async -> UpdateResult {
        guard let value = configuration.url, let baseURL = URL(string: value), SecureUpdateURL.isAllowed(baseURL) else {
            return result(app, latest: nil, status: .failed, detail: UpdateServiceError.unsafeURL.localizedDescription)
        }
        let channel = configuration.channel ?? "latest"
        guard isSafeElectronIdentifier(channel) else {
            return result(app, latest: nil, status: .failed, detail: "The Electron update channel is invalid.")
        }
        let manifestURL = baseURL.appendingPathComponent("\(channel)-mac.yml")
        do {
            let response = try await client.get(manifestURL, timeout: Self.requestTimeout, maximumBytes: Self.electronMaximumBytes)
            try validate(response, maximumBytes: Self.electronMaximumBytes)
            let manifest = try UpdateParsers.parseElectronUpdateManifest(response.data)
            let comparison = Self.compareVersions(manifest.version, installedVersion)
            guard comparison == .orderedDescending else {
                return result(app, latest: manifest.version, status: .current, detail: "Source: \(baseURL.host ?? "Electron feed"). No newer compatible release was found.")
            }
            let artifactBase = (response.finalURL ?? manifestURL).deletingLastPathComponent()
            let candidates = electronArtifactCandidates(manifest.filePaths, baseURL: artifactBase)
            let matching = candidates.first { $0.1 == architecture }
                ?? candidates.first { $0.1 == nil }
            guard let matching else {
                if !manifest.filePaths.isEmpty {
                    return result(app, latest: manifest.version, status: .unsupported, detail: "A newer Electron release exists, but it has no artifact for this Mac architecture.")
                }
                return result(app, latest: manifest.version, status: .failed, detail: "The Electron update manifest has no safe HTTPS artifact link.")
            }
            return result(app, latest: manifest.version, status: .updateAvailable, detail: "Source: \(baseURL.host ?? "Electron feed"). A newer compatible Electron release is available.", actionURL: matching.0)
        } catch {
            return result(app, latest: nil, status: .failed, detail: "Electron update check failed: \(error.localizedDescription)")
        }
    }

    private func checkElectronGitHub(
        _ app: AppRecord,
        installedVersion: String,
        configuration: ElectronUpdateConfiguration
    ) async -> UpdateResult {
        guard let owner = configuration.owner, let repo = configuration.repo,
              isSafeElectronIdentifier(owner), isSafeElectronIdentifier(repo),
              let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return result(app, latest: nil, status: .failed, detail: "The Electron GitHub provider has an invalid owner or repository.")
        }
        do {
            let response = try await client.get(url, timeout: Self.requestTimeout, maximumBytes: Self.electronMaximumBytes)
            try validate(response, maximumBytes: Self.electronMaximumBytes)
            let release = try UpdateParsers.parseGitHubRelease(response.data)
            let channel = configuration.channel ?? "latest"
            guard isSafeElectronIdentifier(channel) else {
                return result(app, latest: nil, status: .failed, detail: "The Electron update channel is invalid.")
            }
            let manifestName = "\(channel)-mac.yml"
            guard let manifestURL = release.assets.first(where: { $0.name.caseInsensitiveCompare(manifestName) == .orderedSame })?.downloadURL else {
                return result(app, latest: release.version, status: .unsupported, detail: "The latest GitHub release has no \(manifestName) asset proving macOS compatibility.")
            }
            let manifestResponse = try await client.get(manifestURL, timeout: Self.requestTimeout, maximumBytes: Self.electronMaximumBytes)
            try validate(manifestResponse, maximumBytes: Self.electronMaximumBytes)
            let manifest = try UpdateParsers.parseElectronUpdateManifest(manifestResponse.data)
            guard Self.compareVersions(manifest.version, installedVersion) == .orderedDescending else {
                return result(app, latest: manifest.version, status: .current, detail: "Source: GitHub \(configuration.owner!)/\(configuration.repo!). No newer compatible release was found.")
            }
            let artifactBase = (manifestResponse.finalURL ?? manifestURL).deletingLastPathComponent()
            let candidates = electronArtifactCandidates(manifest.filePaths, baseURL: artifactBase)
            let matching = candidates.first { $0.1 == architecture } ?? candidates.first { $0.1 == nil }
            guard let matching else {
                return result(app, latest: manifest.version, status: .unsupported, detail: "The latest GitHub release has no artifact for this Mac architecture.")
            }
            guard let actionURL = release.actionURL ?? Optional(matching.0) else {
                return result(app, latest: manifest.version, status: .failed, detail: "GitHub provided no safe HTTPS release link.")
            }
            return result(app, latest: manifest.version, status: .updateAvailable, detail: "Source: GitHub \(configuration.owner!)/\(configuration.repo!). A newer compatible macOS release is available.", actionURL: actionURL)
        } catch {
            return result(app, latest: nil, status: .failed, detail: "Electron GitHub update check failed: \(error.localizedDescription)")
        }
    }

    private func validate(_ response: UpdateHTTPResponse, maximumBytes: Int) throws {
        guard (200..<300).contains(response.statusCode) else { throw UpdateServiceError.httpStatus(response.statusCode) }
        guard response.data.count <= maximumBytes else { throw UpdateServiceError.payloadTooLarge }
        if let finalURL = response.finalURL, !SecureUpdateURL.isAllowed(finalURL) { throw UpdateServiceError.unsafeURL }
    }

    private func isCompatible(_ item: SparkleAppcastItem) -> Bool {
        if UpdateParsers.nonempty(item.channel) != nil { return false }
        if let operatingSystem = item.operatingSystem?.lowercased(), !["macos", "osx"].contains(operatingSystem) { return false }
        let os = "\(currentOS.majorVersion).\(currentOS.minorVersion).\(currentOS.patchVersion)"
        if let minimum = item.minimumSystemVersion, Self.compareVersions(os, minimum) == .orderedAscending { return false }
        if let maximum = item.maximumSystemVersion, Self.compareVersions(os, maximum) == .orderedDescending { return false }
        let requirements = item.hardwareRequirements
        return requirements.isEmpty || requirements.contains("any") || requirements.contains(architecture)
    }

    private func newest(
        _ items: [SparkleAppcastItem],
        version: (SparkleAppcastItem) -> String
    ) -> SparkleAppcastItem? {
        items.max { Self.compareVersions(version($0), version($1)) == .orderedAscending }
    }

    private func result(
        _ app: AppRecord,
        latest: String?,
        status: UpdateStatus,
        detail: String,
        actionURL: URL? = nil
    ) -> UpdateResult {
        UpdateResult(appID: app.id, appName: app.name, installedVersion: app.version, latestVersion: latest, status: status, detail: detail, actionURL: actionURL)
    }

    private func bundleMetadata(at appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL), data.count <= 1_024 * 1_024,
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return object as? [String: Any]
    }

    private func hasAppStoreReceipt(at appURL: URL) -> Bool {
        let receipt = appURL.appendingPathComponent("Contents/_MASReceipt/receipt").standardizedFileURL
        guard FileManager.default.fileExists(atPath: receipt.path),
              let values = try? receipt.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func electronConfiguration(at appURL: URL) -> Result<Data, Error>? {
        let url = appURL.appendingPathComponent("Contents/Resources/app-update.yml").standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 64 * 1_024 else {
            return .failure(UpdateServiceError.malformedPayload)
        }
        do {
            return .success(try Data(contentsOf: url))
        } catch {
            return .failure(error)
        }
    }

    private func isSafeElectronIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private func artifactArchitecture(_ path: String) -> String? {
        let value = path.lowercased()
        if value.contains("arm64") || value.contains("aarch64") { return "arm64" }
        if value.contains("x86_64") || value.contains("x64") { return "x86_64" }
        return nil
    }

    private func electronArtifactCandidates(_ paths: [String], baseURL: URL) -> [(URL, String?)] {
        paths.compactMap { path in
            guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
                  SecureUpdateURL.isAllowed(url) else { return nil }
            return (url, artifactArchitecture(path))
        }
    }

    public static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private struct ParsedVersion {
    enum Identifier { case number(Int), text(String) }
    let core: [Int]
    let prerelease: [Identifier]
    let fallback: String

    init(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.first == "v", value.dropFirst().first?.isNumber == true { value.removeFirst() }
        value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let coreEnd = value.firstIndex { !$0.isNumber && $0 != "." } ?? value.endIndex
        let coreString = String(value[..<coreEnd]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix = String(value[coreEnd...]).trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))
        self.core = coreString.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        self.prerelease = ParsedVersion.identifiers(suffix)
        self.fallback = value
    }

    func compare(to other: ParsedVersion) -> ComparisonResult {
        if core.isEmpty || other.core.isEmpty {
            return fallback.compare(other.fallback, options: [.caseInsensitive, .numeric])
        }
        for index in 0..<max(core.count, other.core.count) {
            let left = index < core.count ? core[index] : 0
            let right = index < other.core.count ? other.core[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        if prerelease.isEmpty != other.prerelease.isEmpty {
            return prerelease.isEmpty ? .orderedDescending : .orderedAscending
        }
        for index in 0..<min(prerelease.count, other.prerelease.count) {
            switch (prerelease[index], other.prerelease[index]) {
            case let (.number(left), .number(right)) where left != right:
                return left < right ? .orderedAscending : .orderedDescending
            case let (.text(left), .text(right)) where left != right:
                return left < right ? .orderedAscending : .orderedDescending
            case (.number, .text): return .orderedAscending
            case (.text, .number): return .orderedDescending
            default: break
            }
        }
        if prerelease.count != other.prerelease.count {
            return prerelease.count < other.prerelease.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func identifiers(_ value: String) -> [Identifier] {
        var output: [Identifier] = []
        var buffer = ""
        var numeric: Bool?
        func flush() {
            guard !buffer.isEmpty else { return }
            output.append(numeric == true ? .number(Int(buffer) ?? 0) : .text(buffer))
            buffer = ""
        }
        for character in value {
            guard character.isLetter || character.isNumber else { flush(); numeric = nil; continue }
            let isNumeric = character.isNumber
            if let numeric, numeric != isNumeric { flush() }
            numeric = isNumeric
            buffer.append(character)
        }
        flush()
        return output
    }
}

private enum SecureUpdateURL {
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        if host == "::" || host == "::1" || host.hasPrefix("::ffff:") || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("ff") { return false }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if host.allSatisfy({ $0.isNumber || $0 == "." }), octets.count != 4 { return false }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (172, 16...31), (192, 168), (224...255, _): return false
            default: break
            }
        }
        return true
    }

    static func isPublicNetworkTarget(_ url: URL) -> Bool {
        guard isAllowed(url), let host = url.host else { return false }
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &addresses) == 0, let first = addresses else { return false }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        var foundAddress = false
        while let entry = current?.pointee {
            if let address = entry.ai_addr {
                foundAddress = true
                if !isPublic(address) { return false }
            }
            current = entry.ai_next
        }
        return foundAddress
    }

    private static func isPublic(_ address: UnsafeMutablePointer<sockaddr>) -> Bool {
        if address.pointee.sa_family == sa_family_t(AF_INET) {
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let first = UInt8((value >> 24) & 0xff)
            let second = UInt8((value >> 16) & 0xff)
            switch (first, second) {
            case (0, _), (10, _), (100, 64...127), (127, _), (169, 254),
                 (172, 16...31), (192, 168), (224...255, _): return false
            default: return true
            }
        }
        if address.pointee.sa_family == sa_family_t(AF_INET6) {
            let bytes: [UInt8] = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            guard bytes.count == 16 else { return false }
            let unspecified = bytes.allSatisfy { $0 == 0 }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let uniqueLocal = bytes[0] & 0xfe == 0xfc
            let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            let multicast = bytes[0] == 0xff
            return !unspecified && !loopback && !uniqueLocal && !linkLocal && !multicast
        }
        return false
    }
}
