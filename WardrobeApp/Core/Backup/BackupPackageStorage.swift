import Foundation

/// Path helpers that match how `FileManager` reports enumerated URLs. The
/// enumerator resolves symlinked components (e.g. `/tmp` -> `/private/tmp`)
/// while `URL.standardizedFileURL`/`resolvingSymlinksInPath` do not, so
/// relative-path math must go through `realpath` on both sides.
enum BackupPathResolver {
    static func realPath(_ path: String) -> String {
        path.withCString { input in
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard let result = realpath(input, &buffer) else { return path }
            return String(cString: result)
        }
    }
}

// MARK: - Controlled Paths

enum BackupPackageLayout {
    static let manifestFileName = "manifest.json"
    static let recordsRelativePath = "metadata/records.json"
    static let checksumsFileName = "checksums.json"
    static let assetsDirectory = "assets"
    static let allowedTopLevelFiles: Set<String> = [
        manifestFileName, checksumsFileName, "metadata/records.json",
    ]

    static func assetRelativePath(_ resourceID: StorageResourceID) -> String {
        "\(assetsDirectory)/\(resourceID.rawValue)"
    }

    static func isAllowedPackagePath(_ relativePath: String) -> Bool {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return false }
        if trimmed == manifestFileName || trimmed == checksumsFileName || trimmed == recordsRelativePath {
            return true
        }
        return trimmed.hasPrefix("\(assetsDirectory)/")
    }

    /// Validates that a package-relative path is safe: relative, normalized,
    /// no `..`, no control characters, no absolute prefix, no home shorthand.
    static func validateRelativePath(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty else { return false }
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return false }
        guard !relativePath.contains("..") else { return false }
        guard !relativePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return true
    }

    static func resolvedURL(in packageURL: URL, relativePath: String) -> URL? {
        guard validateRelativePath(relativePath) else { return nil }
        let url = packageURL.appendingPathComponent(relativePath).standardizedFileURL
        let packagePath = packageURL.standardizedFileURL.path
        guard url.path.hasPrefix(packagePath + "/") else { return nil }
        return url
    }
}

// MARK: - Asset Reading (controlled narrow surface)

struct BackupAssetDigest: Equatable, Sendable {
    let resourceID: StorageResourceID
    let digest: BackupFileDigest
}

protocol BackupAssetReading: Sendable {
    func exists(_ resourceID: StorageResourceID) async throws -> Bool
    func copyAssetToBackup(_ resourceID: StorageResourceID, to destinationURL: URL) async throws -> BackupFileDigest
    func libraryManifest() async throws -> StorageLibraryManifest
}

// MARK: - Package Storage

enum BackupPackageStorage {
    /// Creates the staging package layout (top-level plus `metadata/` and
    /// `assets/`) so every write lands in an existing directory.
    static func createStagingDirectory(at stagingURL: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        try fileManager.createDirectory(
            at: stagingURL.appendingPathComponent("metadata", isDirectory: true),
            withIntermediateDirectories: false
        )
        try fileManager.createDirectory(
            at: stagingURL.appendingPathComponent(BackupPackageLayout.assetsDirectory, isDirectory: true),
            withIntermediateDirectories: false
        )
    }

    static func temporaryStagingURL(destination: URL) -> URL {
        let name = destination.deletingPathExtension().lastPathComponent
        return destination.deletingLastPathComponent().appendingPathComponent(
            ".\(name).wardrobebackup.\(UUID().uuidString.lowercased()).tmp",
            isDirectory: true
        )
    }

    /// Publishes a fully validated staging package to the final destination.
    /// Never deletes an existing backup before the new one is in place.
    static func publish(
        stagingURL: URL,
        destination: URL,
        fileManager: FileManager = .default
    ) throws {
        try Task.checkCancellation()
        let destinationParent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        try validateNoSymbolicLink(at: destinationParent)

        var replacedOldURL: URL?
        if fileManager.fileExists(atPath: destination.path) {
            try validateNoSymbolicLink(at: destination)
            let old = destinationParent.appendingPathComponent(
                ".\(destination.lastPathComponent).old-\(UUID().uuidString.lowercased())"
            )
            try fileManager.moveItem(at: destination, to: old)
            replacedOldURL = old
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: destination)
        } catch {
            if let old = replacedOldURL, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: old, to: destination)
            }
            throw error
        }
        if let old = replacedOldURL, fileManager.fileExists(atPath: old.path) {
            try? fileManager.removeItem(at: old)
        }
    }

    static func validateNoSymbolicLink(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw BackupError.symbolicLink(url.lastPathComponent) }
    }
}

// MARK: - Size Helpers

enum BackupFileSize {
    /// Recursively counts regular-file bytes under a directory (streaming, no symlink following).
    static func bytes(in directory: URL, fileManager: FileManager = .default) throws -> Int64 {
        var total: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true { total = BackupSafeMath.add(total, Int64(values.fileSize ?? 0)) }
        }
        return total
    }
}
