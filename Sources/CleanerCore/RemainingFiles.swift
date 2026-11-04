import AppKit
import Darwin
import Foundation

public struct RemainingFile: Identifiable, Sendable, Hashable {
    public let id: String
    public let url: URL
    public let bundleID: String
    public let category: String
    public let bytes: Int64
    public let reason: String
    let fileSnapshot: RemainingFileSnapshot?

    public init(
        id: String,
        url: URL,
        bundleID: String,
        category: String,
        bytes: Int64,
        reason: String
    ) {
        self.id = id
        self.url = url
        self.bundleID = bundleID
        self.category = category
        self.bytes = bytes
        self.reason = reason
        self.fileSnapshot = try? RemainingFileSnapshot.capture(url)
    }

    init(
        id: String,
        url: URL,
        bundleID: String,
        category: String,
        bytes: Int64,
        reason: String,
        fileSnapshot: RemainingFileSnapshot
    ) {
        self.id = id
        self.url = url
        self.bundleID = bundleID
        self.category = category
        self.bytes = bytes
        self.reason = reason
        self.fileSnapshot = fileSnapshot
    }
}

struct RemainingFileSnapshot: Sendable, Hashable {
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    static func capture(_ url: URL) throws -> RemainingFileSnapshot {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return RemainingFileSnapshot(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
    }
}

struct RemainingFilesRoot: Sendable {
    enum Naming: Sendable {
        case directory
        case file(suffix: String)
        case directoryWithSuffix(String)
    }

    let category: String
    let url: URL
    let naming: Naming
}

public enum RemainingScanner {
    public static func scan(
        installedApps: [AppRecord],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [RemainingFile] {
        scan(
            installedApps: installedApps,
            home: home,
            runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            applicationURLResolver: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        )
    }

    static func scan(
        installedApps: [AppRecord],
        home: URL,
        runningBundleIDs: Set<String>,
        applicationURLResolver: (String) -> URL?
    ) -> [RemainingFile] {
        scan(
            installedApps: installedApps,
            roots: defaultRoots(home: home),
            runningBundleIDs: runningBundleIDs,
            applicationURLResolver: applicationURLResolver
        )
    }

    static func scan(
        installedApps: [AppRecord],
        roots: [RemainingFilesRoot],
        runningBundleIDs: Set<String>,
        applicationURLResolver: (String) -> URL?
    ) -> [RemainingFile] {
        let protectedBundleIDs = installedBundleIDs(in: installedApps).union(runningBundleIDs)
        let fileManager = FileManager.default
        var results: [RemainingFile] = []

        for root in roots {
            let rootURL = root.url.standardizedFileURL
            guard isCanonicalDirectory(rootURL),
                  let children = try? fileManager.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for child in children {
                let url = child.standardizedFileURL
                guard let bundleID = bundleIdentifier(for: url, naming: root.naming),
                      isConservativeBundleIdentifier(bundleID),
                      !bundleID.lowercased().hasPrefix("com.apple."),
                      !isProtected(bundleID, by: protectedBundleIDs),
                      applicationURLResolver(bundleID) == nil,
                      isCanonicalCandidate(url, under: rootURL),
                      let fileSnapshot = try? RemainingFileSnapshot.capture(url) else {
                    continue
                }

                results.append(RemainingFile(
                    id: url.path,
                    url: url,
                    bundleID: bundleID,
                    category: root.category,
                    bytes: root.category == "Containers" ? BoundedStorage.containerBytes(url) : AppScanner.directorySize(url),
                    reason: "Possible leftover for \(bundleID); no owning application was found.",
                    fileSnapshot: fileSnapshot
                ))
            }
        }

        return results.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    static func defaultRoots(home: URL) -> [RemainingFilesRoot] {
        let library = home.standardizedFileURL.appendingPathComponent("Library", isDirectory: true)
        return [
            RemainingFilesRoot(category: "Containers", url: library.appendingPathComponent("Containers", isDirectory: true), naming: .directory),
            RemainingFilesRoot(category: "Application Scripts", url: library.appendingPathComponent("Application Scripts", isDirectory: true), naming: .directory),
            RemainingFilesRoot(category: "Caches", url: library.appendingPathComponent("Caches", isDirectory: true), naming: .directory),
            RemainingFilesRoot(category: "Preferences", url: library.appendingPathComponent("Preferences", isDirectory: true), naming: .file(suffix: ".plist")),
            RemainingFilesRoot(category: "Application Support", url: library.appendingPathComponent("Application Support", isDirectory: true), naming: .directory),
            RemainingFilesRoot(category: "Logs", url: library.appendingPathComponent("Logs", isDirectory: true), naming: .directory),
            RemainingFilesRoot(category: "Saved Application State", url: library.appendingPathComponent("Saved Application State", isDirectory: true), naming: .directoryWithSuffix(".savedState")),
        ]
    }

    static func hasOwner(
        for bundleID: String,
        installedApps: [AppRecord],
        runningBundleIDs: Set<String>,
        applicationURLResolver: (String) -> URL?
    ) -> Bool {
        let protectedBundleIDs = installedBundleIDs(in: installedApps).union(runningBundleIDs)
        return isProtected(bundleID, by: protectedBundleIDs)
            || applicationURLResolver(bundleID) != nil
    }

    private static func installedBundleIDs(in apps: [AppRecord]) -> Set<String> {
        var bundleIDs = Set(apps.map(\.bundleID).filter { !$0.isEmpty })
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let bundleExtensions: Set<String> = ["app", "appex", "xpc", "bundle"]

        for app in apps {
            let appURL = app.url.standardizedFileURL
            guard let enumerator = FileManager.default.enumerator(
                at: appURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                guard bundleExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    continue
                }
                if let bundleID = AppScanner.bundleIdentifier(at: url), !bundleID.isEmpty {
                    bundleIDs.insert(bundleID)
                }
            }
        }
        return bundleIDs
    }

    private static func isProtected(_ candidate: String, by installedBundleIDs: Set<String>) -> Bool {
        installedBundleIDs.contains(candidate)
            || installedBundleIDs.contains { candidate.hasPrefix($0 + ".") }
    }

    private static func bundleIdentifier(for url: URL, naming: RemainingFilesRoot.Naming) -> String? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { return nil }

        switch naming {
        case .directory:
            guard values?.isDirectory == true else { return nil }
            return url.lastPathComponent
        case .file(let suffix):
            guard values?.isRegularFile == true, url.lastPathComponent.hasSuffix(suffix) else { return nil }
            return String(url.lastPathComponent.dropLast(suffix.count))
        case .directoryWithSuffix(let suffix):
            guard values?.isDirectory == true, url.lastPathComponent.hasSuffix(suffix) else { return nil }
            return String(url.lastPathComponent.dropLast(suffix.count))
        }
    }

    private static func isConservativeBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, let last = part.last,
                  first != "-", last != "-" else { return false }
            return part.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
        }
    }

    private static func isCanonicalDirectory(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              url.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isCanonicalCandidate(_ url: URL, under root: URL) -> Bool {
        url.path.hasPrefix(root.path + "/")
            && url.deletingLastPathComponent().path == root.path
            && url.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

public enum RemainingTrashServiceError: Error {
    case invalidSelection(URL)
    case changedCandidate(URL)
    case partialFailure(moved: [URL], failed: URL, underlying: Error)
}

extension RemainingTrashServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSelection(let url):
            return "The possible leftover is no longer a valid deletion candidate: \(url.path)"
        case .changedCandidate(let url):
            return "The possible leftover changed before it could be moved to Trash: \(url.path)"
        case .partialFailure(let moved, let failed, let underlying):
            let movedPaths = moved.map(\.path).joined(separator: ", ")
            return "Moved [\(movedPaths)] but could not move \(failed.path): \(underlying.localizedDescription)"
        }
    }
}

public enum RemainingTrashService {
    public static func moveToTrash(
        _ files: [RemainingFile],
        installedApps: [AppRecord]
    ) throws -> [URL] {
        try moveToTrash(
            files,
            installedApps: installedApps,
            home: FileManager.default.homeDirectoryForCurrentUser,
            runningBundleIDsProvider: {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            },
            applicationURLResolver: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            applicationScanRoots: applicationScanRoots(
                installedApps: installedApps,
                home: FileManager.default.homeDirectoryForCurrentUser
            ),
            beforeMove: nil
        )
    }

    static func moveToTrash(
        _ files: [RemainingFile],
        installedApps: [AppRecord],
        home: URL,
        runningBundleIDsProvider: () -> Set<String>,
        applicationURLResolver: (String) -> URL?,
        applicationScanRoots: [URL],
        beforeMove: ((URL) throws -> Void)?
    ) throws -> [URL] {
        guard Set(files.map(\.id)).count == files.count else {
            throw RemainingTrashServiceError.invalidSelection(files.first?.url ?? home)
        }

        let refreshedApps = refreshedInstalledApps(installedApps, roots: applicationScanRoots)
        let fresh = RemainingScanner.scan(
            installedApps: refreshedApps,
            home: home,
            runningBundleIDs: runningBundleIDsProvider(),
            applicationURLResolver: applicationURLResolver
        )
        let freshByID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        var validated: [RemainingFile] = []

        for provided in files {
            guard provided.url.isFileURL,
                  provided.id == provided.url.path,
                  provided.url.path == provided.url.standardizedFileURL.path,
                  let current = freshByID[provided.id],
                  current == provided,
                  current.fileSnapshot != nil else {
                throw RemainingTrashServiceError.invalidSelection(provided.url)
            }
            try TrashService.validateCanonicalNonSymlink(current.url)
            validated.append(current)
        }

        var moved: [URL] = []
        for item in validated {
            do {
                try beforeMove?(item.url)
                let latestApps = refreshedInstalledApps(installedApps, roots: applicationScanRoots)
                guard !RemainingScanner.hasOwner(
                    for: item.bundleID,
                    installedApps: latestApps,
                    runningBundleIDs: runningBundleIDsProvider(),
                    applicationURLResolver: applicationURLResolver
                ) else {
                    throw RemainingTrashServiceError.invalidSelection(item.url)
                }
                try TrashService.validateCanonicalNonSymlink(item.url)
                guard try RemainingFileSnapshot.capture(item.url) == item.fileSnapshot else {
                    throw RemainingTrashServiceError.changedCandidate(item.url)
                }

                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingURL)
                moved.append((resultingURL as URL?) ?? item.url)
            } catch let error as RemainingTrashServiceError {
                if moved.isEmpty { throw error }
                throw RemainingTrashServiceError.partialFailure(moved: moved, failed: item.url, underlying: error)
            } catch {
                throw RemainingTrashServiceError.partialFailure(moved: moved, failed: item.url, underlying: error)
            }
        }
        return moved
    }

    private static func applicationScanRoots(installedApps: [AppRecord], home: URL) -> [URL] {
        let standardRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.standardizedFileURL.appendingPathComponent("Applications", isDirectory: true),
        ]
        return uniqueURLs(standardRoots + installedApps.map { $0.url.deletingLastPathComponent() })
    }

    private static func refreshedInstalledApps(_ installedApps: [AppRecord], roots: [URL]) -> [AppRecord] {
        let existingCallerApps = installedApps.filter {
            FileManager.default.fileExists(atPath: $0.url.standardizedFileURL.path)
        }
        let rescanned = roots.isEmpty ? [] : AppScanner.scan(roots: uniqueURLs(roots), measureSizes: false)
        var byPath = Dictionary(uniqueKeysWithValues: existingCallerApps.map { ($0.url.standardizedFileURL.path, $0) })
        for app in rescanned {
            byPath[app.url.standardizedFileURL.path] = app
        }
        return Array(byPath.values)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.compactMap {
            let url = $0.standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }
}
