import Foundation

struct StorageConfiguration: Sendable {
    static let layoutVersion = 1

    let rootURL: URL

    static func production(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTestProcess: Bool = NSClassFromString("XCTestCase") != nil
    ) throws -> StorageConfiguration {
#if DEBUG
        if let override = environment["WARDROBE_STORAGE_ROOT_OVERRIDE"], !override.isEmpty {
            return StorageConfiguration(rootURL: URL(fileURLWithPath: override, isDirectory: true))
        }
        if environment["XCTestConfigurationFilePath"] != nil || isTestProcess {
            return StorageConfiguration(
                rootURL: fileManager.temporaryDirectory.appendingPathComponent(
                    "WardrobeTestHost-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            )
        }
#endif
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw StorageError.missingBundleIdentifier
        }
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StorageError.applicationSupportUnavailable
        }
        return StorageConfiguration(
            rootURL: applicationSupport
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Wardrobe", isDirectory: true)
        )
    }
}

struct StorageLibraryManifest: Codable, Equatable, Sendable {
    let storageLayoutVersion: Int
    let libraryID: UUID
    let createdAt: Date
}

struct StoredImageResources: Equatable, Sendable {
    let original: StorageResourceID
    let thumbnail: StorageResourceID
    let processedPlaceholder: StorageResourceID?
    let metadata: ImageMetadata
}

struct StoredGenerationResources: Equatable, Sendable {
    let result: StorageResourceID
    let thumbnail: StorageResourceID
    let metadata: ImageMetadata
}

struct StorageTemporaryFile: Sendable {
    let operationID: UUID
    let url: URL
}

enum StorageError: Error, Equatable, LocalizedError {
    case missingBundleIdentifier
    case applicationSupportUnavailable
    case unsupportedLayoutVersion(found: Int)
    case invalidLibraryManifest
    case resourceNotFound(StorageResourceID)
    case resourceAlreadyExists(StorageResourceID)
    case resourceDirectoryAlreadyExists(StorageOwner)
    case unsafeResolvedPath
    case symbolicLinkNotAllowed
    case invalidCacheKey
    case invalidFileExtension

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier: "The application bundle identifier is unavailable."
        case .applicationSupportUnavailable: "Application Support is unavailable."
        case let .unsupportedLayoutVersion(found): "Unsupported storage layout version: \(found)."
        case .invalidLibraryManifest: "The storage library manifest is invalid."
        case let .resourceNotFound(id): "Storage resource not found: \(id.rawValue)."
        case let .resourceAlreadyExists(id): "Storage resource already exists: \(id.rawValue)."
        case let .resourceDirectoryAlreadyExists(owner): "Storage directory already exists for \(owner.id)."
        case .unsafeResolvedPath: "The resolved path is outside the storage root."
        case .symbolicLinkNotAllowed: "Symbolic links are not allowed in managed storage paths."
        case .invalidCacheKey: "The cache key is invalid."
        case .invalidFileExtension: "The temporary file extension is invalid."
        }
    }
}

protocol StorageServing: Sendable {
    func createResourceDirectory(for owner: StorageOwner) async throws
    func write(_ data: Data, to resourceID: StorageResourceID) async throws
    func read(_ resourceID: StorageResourceID) async throws -> Data
    func exists(_ resourceID: StorageResourceID) async throws -> Bool
    func move(from source: StorageResourceID, to destination: StorageResourceID) async throws
    func delete(_ resourceID: StorageResourceID) async throws
    func deleteResourceDirectory(for owner: StorageOwner) async throws
    func importImage(from sourceURL: URL, for owner: StorageOwner) async throws -> StoredImageResources
    func saveGenerationResult(_ data: Data, mediaType: String, generationID: UUID) async throws -> StoredGenerationResources
    func createTemporaryFile(data: Data, operationID: UUID, fileExtension: String) async throws -> StorageTemporaryFile
    func discardTemporaryOperation(_ operationID: UUID) async throws
    func writeCache(_ data: Data, namespace: String, key: UUID) async throws
    func readCache(namespace: String, key: UUID) async throws -> Data?
    func deleteCacheFile(namespace: String, key: UUID) async throws
    func persistentStorageSize() async throws -> Int64
    func cacheStorageSize() async throws -> Int64
    func storageRootLocation() async -> URL
}

actor StorageService: StorageServing, ImageProcessingStorageServing {
    private static let managedDirectories = [
        "database", "garments", "persons", "generations", "outfits", "staging", "cache", "backups",
    ]

    private let fileManager: FileManager
    private let configuration: StorageConfiguration
    private let thumbnailGenerator: any ImageThumbnailGenerating
    private let thumbnailConfiguration: ThumbnailConfiguration

    init(
        configuration: StorageConfiguration,
        fileManager: FileManager = .default,
        thumbnailGenerator: any ImageThumbnailGenerating = ImageIOThumbnailGenerator(),
        thumbnailConfiguration: ThumbnailConfiguration = .wardrobeDefault
    ) throws {
        self.configuration = configuration
        self.fileManager = fileManager
        self.thumbnailGenerator = thumbnailGenerator
        self.thumbnailConfiguration = thumbnailConfiguration
        try Self.initializeLibrary(configuration: configuration, fileManager: fileManager)
    }

    static func production() throws -> StorageService {
        try StorageService(configuration: .production())
    }

    func createResourceDirectory(for owner: StorageOwner) throws {
        let directory = try ownerDirectory(for: owner)
        try ensureNoSymbolicLinkInExistingPath(to: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func write(_ data: Data, to resourceID: StorageResourceID) throws {
        let destination = try resolvedURL(for: resourceID)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw StorageError.resourceAlreadyExists(resourceID)
        }
        let operation = UUID()
        let operationDirectory = stagingDirectory.appendingPathComponent(operation.uuidString.lowercased(), isDirectory: true)
        var createdOwnerDirectory = false
        do {
            try fileManager.createDirectory(at: operationDirectory, withIntermediateDirectories: false)
            let stagedFile = operationDirectory.appendingPathComponent(destination.lastPathComponent)
            try data.write(to: stagedFile, options: [.atomic])
            let ownerDirectory = destination.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: ownerDirectory.path) {
                try fileManager.createDirectory(at: ownerDirectory, withIntermediateDirectories: false)
                createdOwnerDirectory = true
            }
            try ensureNoSymbolicLinkInExistingPath(to: ownerDirectory)
            try fileManager.moveItem(at: stagedFile, to: destination)
            try removeIfExists(operationDirectory)
        } catch {
            try? removeIfExists(operationDirectory)
            if createdOwnerDirectory,
               (try? fileManager.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).isEmpty) == true {
                try? removeIfExists(destination.deletingLastPathComponent())
            }
            throw error
        }
    }

    func read(_ resourceID: StorageResourceID) throws -> Data {
        let url = try existingResolvedURL(for: resourceID)
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func exists(_ resourceID: StorageResourceID) throws -> Bool {
        let url = try resolvedURL(for: resourceID)
        try ensureNoSymbolicLinkInExistingPath(to: url)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    func move(from source: StorageResourceID, to destination: StorageResourceID) throws {
        let sourceURL = try existingResolvedURL(for: source)
        let destinationURL = try resolvedURL(for: destination)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw StorageError.resourceAlreadyExists(destination)
        }
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destinationDirectory.path) {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        }
        try ensureNoSymbolicLinkInExistingPath(to: destinationDirectory)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func delete(_ resourceID: StorageResourceID) throws {
        let url = try existingResolvedURL(for: resourceID)
        try fileManager.removeItem(at: url)
    }

    func deleteResourceDirectory(for owner: StorageOwner) throws {
        let directory = try ownerDirectory(for: owner)
        try ensureNoSymbolicLinkInExistingPath(to: directory)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func importImage(from sourceURL: URL, for owner: StorageOwner) throws -> StoredImageResources {
        guard owner.kind == .garment || owner.kind == .person else {
            throw StorageResourceIDError.incompatibleResourceKind
        }
        let metadata = try thumbnailGenerator.inspectImage(at: sourceURL)
        let original = try StorageResourceID(
            owner: owner,
            kind: .original(fileExtension: metadata.format.preferredFileExtension)
        )
        let thumbnail = try StorageResourceID(owner: owner, kind: .thumbnail)
        let processed = try StorageResourceID(owner: owner, kind: .processed)
        let destinationDirectory = try ownerDirectory(for: owner)
        guard !fileManager.fileExists(atPath: destinationDirectory.path) else {
            throw StorageError.resourceDirectoryAlreadyExists(owner)
        }

        let operation = UUID()
        let operationDirectory = stagingDirectory.appendingPathComponent(operation.uuidString.lowercased(), isDirectory: true)
        do {
            try fileManager.createDirectory(at: operationDirectory, withIntermediateDirectories: false)
            let stagedOriginal = operationDirectory.appendingPathComponent(originalFileName(for: metadata.format))
            try fileManager.copyItem(at: sourceURL, to: stagedOriginal)
            _ = try thumbnailGenerator.inspectImage(at: stagedOriginal)
            let thumbnailData = try thumbnailGenerator.makeThumbnail(
                at: stagedOriginal,
                configuration: thumbnailConfiguration
            )
            try thumbnailData.write(
                to: operationDirectory.appendingPathComponent("thumbnail.jpg"),
                options: [.atomic]
            )
            try fileManager.moveItem(at: operationDirectory, to: destinationDirectory)
            return StoredImageResources(
                original: original,
                thumbnail: thumbnail,
                processedPlaceholder: processed,
                metadata: metadata
            )
        } catch {
            try? removeIfExists(operationDirectory)
            if fileManager.fileExists(atPath: destinationDirectory.path) {
                try? removeIfExists(destinationDirectory)
            }
            throw error
        }
    }

    func saveGenerationResult(
        _ data: Data,
        mediaType: String,
        generationID: UUID
    ) throws -> StoredGenerationResources {
        let operationID = UUID()
        let temporary = try createTemporaryFile(
            data: data,
            operationID: operationID,
            fileExtension: fileExtension(for: mediaType)
        )
        defer { try? discardTemporaryOperation(operationID) }

        let metadata = try thumbnailGenerator.inspectImage(at: temporary.url)
        let owner = StorageOwner(kind: .generation, id: generationID)
        let result = try StorageResourceID(
            owner: owner,
            kind: .generationResult(fileExtension: metadata.format.preferredFileExtension)
        )
        let thumbnail = try StorageResourceID(owner: owner, kind: .thumbnail)
        let destinationDirectory = try ownerDirectory(for: owner)
        guard !fileManager.fileExists(atPath: destinationDirectory.path) else {
            throw StorageError.resourceDirectoryAlreadyExists(owner)
        }

        let publishDirectory = stagingDirectory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try fileManager.createDirectory(at: publishDirectory, withIntermediateDirectories: false)
            try fileManager.copyItem(
                at: temporary.url,
                to: publishDirectory.appendingPathComponent("result.\(metadata.format.preferredFileExtension)")
            )
            let thumbnailData = try thumbnailGenerator.makeThumbnail(
                at: temporary.url,
                configuration: thumbnailConfiguration
            )
            try thumbnailData.write(to: publishDirectory.appendingPathComponent("thumbnail.jpg"), options: [.atomic])
            try fileManager.moveItem(at: publishDirectory, to: destinationDirectory)
            return StoredGenerationResources(result: result, thumbnail: thumbnail, metadata: metadata)
        } catch {
            try? removeIfExists(publishDirectory)
            if fileManager.fileExists(atPath: destinationDirectory.path) {
                try? removeIfExists(destinationDirectory)
            }
            throw error
        }
    }

    func createTemporaryFile(data: Data, operationID: UUID = UUID(), fileExtension: String) throws -> StorageTemporaryFile {
        guard isSafeExtension(fileExtension) else { throw StorageError.invalidFileExtension }
        let directory = stagingDirectory.appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("temporary.\(fileExtension.lowercased())")
        do {
            try data.write(to: url, options: [.atomic])
            return StorageTemporaryFile(operationID: operationID, url: url)
        } catch {
            try? removeIfExists(directory)
            throw error
        }
    }

    func discardTemporaryOperation(_ operationID: UUID) throws {
        let directory = stagingDirectory.appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        try removeIfExists(directory)
    }

    func beginImageProcessing(
        originalResourceID: StorageResourceID
    ) throws -> ImageProcessingWorkspace {
        try Task.checkCancellation()
        let owner = originalResourceID.owner
        guard owner.kind == .garment || owner.kind == .person,
              originalResourceID.rawValue.split(separator: "/").last?.hasPrefix("original.") == true
        else {
            throw ImageProcessingError.invalidOriginalResource
        }

        let source = try existingResolvedURL(for: originalResourceID)
        _ = try thumbnailGenerator.inspectImage(at: source)
        let operationID = UUID()
        let directory = processingWorkspaceDirectory(operationID)
        let input = directory.appendingPathComponent(
            "input.\(source.pathExtension.lowercased())",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try fileManager.copyItem(at: source, to: input)
            try Task.checkCancellation()
            return ImageProcessingWorkspace(
                operationID: operationID,
                originalResourceID: originalResourceID,
                inputURL: input,
                processedOutputURL: directory.appendingPathComponent("processed.png"),
                thumbnailOutputURL: directory.appendingPathComponent("thumbnail.jpg")
            )
        } catch {
            try? removeIfExists(directory)
            throw error
        }
    }

    func publishImageProcessingOutputs(
        from workspace: ImageProcessingWorkspace
    ) throws -> PublishedImageProcessingResources {
        try Task.checkCancellation()
        let directory = try validatedProcessingWorkspace(workspace)
        try ensureNoSymbolicLinkInExistingPath(to: workspace.processedOutputURL)
        try ensureNoSymbolicLinkInExistingPath(to: workspace.thumbnailOutputURL)
        let processedMetadata = try thumbnailGenerator.inspectImage(at: workspace.processedOutputURL)
        let thumbnailMetadata = try thumbnailGenerator.inspectImage(at: workspace.thumbnailOutputURL)
        guard processedMetadata.format == .png, thumbnailMetadata.format == .jpeg else {
            throw ImageProcessingError.outputValidationFailed
        }

        let owner = workspace.originalResourceID.owner
        let processed = try StorageResourceID(owner: owner, kind: .processed)
        let thumbnail = try StorageResourceID(owner: owner, kind: .thumbnail)
        let processedDestination = try resolvedURL(for: processed)
        let thumbnailDestination = try resolvedURL(for: thumbnail)
        guard !fileManager.fileExists(atPath: processedDestination.path) else {
            throw StorageError.resourceAlreadyExists(processed)
        }

        let previousThumbnail = directory.appendingPathComponent("previous-thumbnail.jpg")
        var movedPreviousThumbnail = false
        var publishedProcessed = false
        var publishedThumbnail = false
        do {
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: thumbnailDestination.path) {
                try ensureNoSymbolicLinkInExistingPath(to: thumbnailDestination)
                try fileManager.moveItem(at: thumbnailDestination, to: previousThumbnail)
                movedPreviousThumbnail = true
            }
            try fileManager.moveItem(at: workspace.processedOutputURL, to: processedDestination)
            publishedProcessed = true
            try fileManager.moveItem(at: workspace.thumbnailOutputURL, to: thumbnailDestination)
            publishedThumbnail = true
            try removeIfExists(directory)
            return PublishedImageProcessingResources(processed: processed, thumbnail: thumbnail)
        } catch {
            if publishedThumbnail { try? removeIfExists(thumbnailDestination) }
            if publishedProcessed { try? removeIfExists(processedDestination) }
            if movedPreviousThumbnail,
               fileManager.fileExists(atPath: previousThumbnail.path),
               !fileManager.fileExists(atPath: thumbnailDestination.path) {
                try? fileManager.moveItem(at: previousThumbnail, to: thumbnailDestination)
            }
            throw error
        }
    }

    func discardImageProcessingWorkspace(_ operationID: UUID) throws {
        try removeIfExists(processingWorkspaceDirectory(operationID))
    }

    func writeCache(_ data: Data, namespace: String, key: UUID) throws {
        guard namespace == "previews" || namespace == "provider" else { throw StorageError.invalidCacheKey }
        let directory = cacheDirectory.appendingPathComponent(namespace, isDirectory: true)
        let destination = directory.appendingPathComponent(key.uuidString.lowercased())
        try data.write(to: destination, options: [.atomic])
    }

    func readCache(namespace: String, key: UUID) throws -> Data? {
        guard namespace == "previews" || namespace == "provider" else { throw StorageError.invalidCacheKey }
        let url = cacheDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(key.uuidString.lowercased())
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func deleteCacheFile(namespace: String, key: UUID) throws {
        guard namespace == "previews" || namespace == "provider" else { throw StorageError.invalidCacheKey }
        let url = cacheDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(key.uuidString.lowercased())
        try removeIfExists(url)
    }

    func persistentStorageSize() throws -> Int64 {
        try size(of: ["garments", "persons", "generations", "outfits", "backups"])
    }

    func cacheStorageSize() throws -> Int64 { try size(of: ["cache"]) }

    // Diagnostics and tests may display this location. Persistent models never store it.
    func storageRootLocation() -> URL { configuration.rootURL.standardizedFileURL }

    func libraryManifest() throws -> StorageLibraryManifest {
        try Self.readManifest(at: configuration.rootURL.appendingPathComponent("library.json"))
    }

    private static func initializeLibrary(
        configuration: StorageConfiguration,
        fileManager: FileManager
    ) throws {
        let root = configuration.rootURL.standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try rejectSymbolicLink(at: root, fileManager: fileManager)
        for directory in managedDirectories {
            let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
            if fileManager.fileExists(atPath: directoryURL.path) {
                try rejectSymbolicLink(at: directoryURL, fileManager: fileManager)
            }
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
        for namespace in ["previews", "provider"] {
            let namespaceURL = root.appendingPathComponent("cache/\(namespace)", isDirectory: true)
            if fileManager.fileExists(atPath: namespaceURL.path) {
                try rejectSymbolicLink(at: namespaceURL, fileManager: fileManager)
            }
            try fileManager.createDirectory(
                at: namespaceURL,
                withIntermediateDirectories: true
            )
        }

        let manifestURL = root.appendingPathComponent("library.json")
        if fileManager.fileExists(atPath: manifestURL.path) {
            let manifest = try readManifest(at: manifestURL)
            guard manifest.storageLayoutVersion == StorageConfiguration.layoutVersion else {
                throw StorageError.unsupportedLayoutVersion(found: manifest.storageLayoutVersion)
            }
        } else {
            let manifest = StorageLibraryManifest(
                storageLayoutVersion: StorageConfiguration.layoutVersion,
                libraryID: UUID(),
                createdAt: .now
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
        }
    }

    private static func readManifest(at url: URL) throws -> StorageLibraryManifest {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(StorageLibraryManifest.self, from: Data(contentsOf: url))
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError.invalidLibraryManifest
        }
    }

    private static func rejectSymbolicLink(at url: URL, fileManager: FileManager) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw StorageError.symbolicLinkNotAllowed }
    }

    private var stagingDirectory: URL {
        configuration.rootURL.appendingPathComponent("staging", isDirectory: true)
    }

    private var cacheDirectory: URL {
        configuration.rootURL.appendingPathComponent("cache", isDirectory: true)
    }

    private func processingWorkspaceDirectory(_ operationID: UUID) -> URL {
        stagingDirectory.appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
    }

    private func validatedProcessingWorkspace(_ workspace: ImageProcessingWorkspace) throws -> URL {
        let expectedDirectory = processingWorkspaceDirectory(workspace.operationID).standardizedFileURL
        guard workspace.inputURL.deletingLastPathComponent().standardizedFileURL == expectedDirectory,
              workspace.processedOutputURL.standardizedFileURL == expectedDirectory.appendingPathComponent("processed.png"),
              workspace.thumbnailOutputURL.standardizedFileURL == expectedDirectory.appendingPathComponent("thumbnail.jpg")
        else {
            throw StorageError.unsafeResolvedPath
        }
        try ensureNoSymbolicLinkInExistingPath(to: expectedDirectory)
        return expectedDirectory
    }

    private func ownerDirectory(for owner: StorageOwner) throws -> URL {
        let directory = configuration.rootURL
            .appendingPathComponent(owner.kind.rawValue, isDirectory: true)
            .appendingPathComponent(owner.directoryName, isDirectory: true)
            .standardizedFileURL
        try validateInsideRoot(directory)
        return directory
    }

    private func resolvedURL(for resourceID: StorageResourceID) throws -> URL {
        let url = configuration.rootURL
            .appendingPathComponent(resourceID.rawValue, isDirectory: false)
            .standardizedFileURL
        try validateInsideRoot(url)
        return url
    }

    private func existingResolvedURL(for resourceID: StorageResourceID) throws -> URL {
        let url = try resolvedURL(for: resourceID)
        try ensureNoSymbolicLinkInExistingPath(to: url)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw StorageError.resourceNotFound(resourceID)
        }
        return url
    }

    private func validateInsideRoot(_ url: URL) throws {
        let rootPath = configuration.rootURL.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw StorageError.unsafeResolvedPath
        }
    }

    private func ensureNoSymbolicLinkInExistingPath(to url: URL) throws {
        let root = configuration.rootURL.standardizedFileURL
        try validateInsideRoot(url)
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        if rootValues.isSymbolicLink == true { throw StorageError.symbolicLinkNotAllowed }
        let relative = url.path.dropFirst(root.path.count).split(separator: "/")
        var current = root
        for component in relative {
            current.appendPathComponent(String(component))
            guard fileManager.fileExists(atPath: current.path) else { continue }
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw StorageError.symbolicLinkNotAllowed }
        }
    }

    private func removeIfExists(_ url: URL) throws {
        try validateInsideRoot(url)
        try ensureNoSymbolicLinkInExistingPath(to: url)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func originalFileName(for format: SupportedImageFormat) -> String {
        "original.\(format.preferredFileExtension)"
    }

    private func fileExtension(for mediaType: String) throws -> String {
        switch mediaType.lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/heic": "heic"
        case "image/heif": "heif"
        default: throw ImageValidationError.unsupportedFormat
        }
    }

    private func isSafeExtension(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private func size(of topLevelDirectories: [String]) throws -> Int64 {
        var total: Int64 = 0
        for name in topLevelDirectories {
            let directory = configuration.rootURL.appendingPathComponent(name, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
            }
        }
        return total
    }
}
