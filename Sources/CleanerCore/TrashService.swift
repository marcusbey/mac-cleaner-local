import AppKit
import Foundation

public enum TrashServiceError: Error {
    case invalidApplicationPath(URL)
    case nonCanonicalPath(URL)
    case symbolicLink(URL)
    case systemApplication(URL)
    case runningApplication(URL)
    case currentApplication(URL)
    case staleRelatedFiles(expected: [RelatedFile], provided: [RelatedFile])
    case partialFailure(moved: [URL], failed: URL, underlying: Error)
}

extension TrashServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidApplicationPath(let url):
            return "The application is outside supported application locations: \(url.path)"
        case .nonCanonicalPath(let url):
            return "The path must be a canonical file path: \(url.path)"
        case .symbolicLink(let url):
            return "Symbolic-link paths cannot be moved: \(url.path)"
        case .systemApplication(let url):
            return "System applications cannot be moved: \(url.path)"
        case .runningApplication(let url):
            return "Quit the application before moving it to Trash: \(url.path)"
        case .currentApplication(let url):
            return "App Cleaner cannot move itself to Trash: \(url.path)"
        case .staleRelatedFiles:
            return "The selected related files no longer match the files currently discovered on disk."
        case .partialFailure(let moved, let failed, let underlying):
            let movedPaths = moved.map(\.path).joined(separator: ", ")
            return "Moved [\(movedPaths)] but could not move \(failed.path): \(underlying.localizedDescription)"
        }
    }
}

public enum TrashService {
    public static func moveToTrash(app: AppRecord, files: [RelatedFile]) throws -> [URL] {
        let appURL = app.url.standardizedFileURL
        try validateApplication(app, at: app.url)

        let freshFiles = try validatedRelatedFiles(files, for: app)
        for file in freshFiles {
            try validateCanonicalNonSymlink(file.url)
        }

        var moved: [URL] = []
        for source in [appURL] + freshFiles.map(\.url) {
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
                moved.append((resultingURL as URL?) ?? source)
            } catch {
                throw TrashServiceError.partialFailure(moved: moved, failed: source, underlying: error)
            }
        }
        return moved
    }

    static func validatedRelatedFiles(
        _ provided: [RelatedFile],
        for app: AppRecord,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [RelatedFile] {
        let fresh = AppScanner.relatedFiles(for: app, home: home)
        let freshByID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        let uniqueIDs = Set(provided.map(\.id))
        guard uniqueIDs.count == provided.count else {
            throw TrashServiceError.staleRelatedFiles(expected: fresh, provided: provided)
        }

        var validated: [RelatedFile] = []
        for file in provided {
            guard file.url.isFileURL,
                  file.url.path == file.url.standardizedFileURL.path,
                  file.id == file.url.path,
                  let current = freshByID[file.id],
                  current.url.standardizedFileURL.path == file.url.standardizedFileURL.path else {
                throw TrashServiceError.staleRelatedFiles(expected: fresh, provided: provided)
            }
            validated.append(current)
        }
        return validated
    }

    static func validateApplication(_ app: AppRecord, at originalURL: URL) throws {
        let appURL = originalURL.standardizedFileURL
        guard app.id == appURL.path,
              appURL.pathExtension.lowercased() == "app",
              isInsideAllowedApplicationsRoot(appURL) else {
            throw TrashServiceError.invalidApplicationPath(appURL)
        }
        try validateCanonicalNonSymlink(originalURL)

        try validateRecordedBundleIdentifier(app, at: appURL)

        if appURL.path.hasPrefix("/System/") || app.bundleID.hasPrefix("com.apple.") {
            throw TrashServiceError.systemApplication(appURL)
        }

        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        if appURL == currentBundleURL
            || (!app.bundleID.isEmpty && app.bundleID == Bundle.main.bundleIdentifier) {
            throw TrashServiceError.currentApplication(appURL)
        }

        let isRunning = NSWorkspace.shared.runningApplications.contains { runningApp in
            if let runningURL = runningApp.bundleURL?.standardizedFileURL, runningURL == appURL {
                return true
            }
            return !app.bundleID.isEmpty && runningApp.bundleIdentifier == app.bundleID
        }
        if isRunning {
            throw TrashServiceError.runningApplication(appURL)
        }
    }

    static func validateCanonicalNonSymlink(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        guard url.isFileURL, url.path == standardized.path else {
            throw TrashServiceError.nonCanonicalPath(url)
        }
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard standardized.path == standardized.resolvingSymlinksInPath().standardizedFileURL.path,
              (try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TrashServiceError.symbolicLink(url)
        }
    }

    static func validateRecordedBundleIdentifier(_ app: AppRecord, at appURL: URL) throws {
        guard !app.bundleID.isEmpty,
              AppScanner.bundleIdentifier(at: appURL) == app.bundleID else {
            throw TrashServiceError.invalidApplicationPath(appURL)
        }
    }

    private static func isInsideAllowedApplicationsRoot(_ url: URL) -> Bool {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support/Adobe/Adobe Desktop Common", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support/Adobe/Creative Cloud Libraries", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support/Adobe/Adobe OS Extension", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support/Microsoft/MAU2.0", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ].map { $0.standardizedFileURL.path }

        return roots.contains { root in
            url.path == root || url.path.hasPrefix(root + "/")
        }
    }
}
