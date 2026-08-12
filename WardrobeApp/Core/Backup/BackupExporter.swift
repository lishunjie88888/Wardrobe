import CryptoKit
import Foundation

/// Creates validated `.wardrobebackup` packages from a live library.
///
/// The exporter never reads Keychain, cache, staging, logs, external handoff
/// workspaces or other backups; assets are collected exclusively from the
/// logical metadata resource references.
actor BackupExporter {
    private let configuration: StorageConfiguration
    private let metadataExporter: any BackupMetadataExporting
    private let assetReader: any BackupAssetReading
    private let capacity: any BackupCapacityChecking

    init(
        configuration: StorageConfiguration,
        metadataExporter: any BackupMetadataExporting,
        assetReader: any BackupAssetReading,
        capacity: any BackupCapacityChecking = SystemBackupCapacity()
    ) {
        self.configuration = configuration
        self.metadataExporter = metadataExporter
        self.assetReader = assetReader
        self.capacity = capacity
    }

    // MARK: - Export

    func createBackup(
        destination: URL,
        progress: @Sendable (BackupPhase) -> Void = { _ in }
    ) async throws -> BackupSummary {
        try Task.checkCancellation()
        progress(.preparing)

        let root = configuration.rootURL.standardizedFileURL
        if try RestoreTransactionWorkspace.discoverPending(
            parent: root.deletingLastPathComponent(),
            ) != nil {
            throw BackupError.pendingRestoreExists
        }
        let destinationParent = destination.deletingLastPathComponent().standardizedFileURL
        guard !root.path.hasPrefix(destination.path + "/"),
              !destination.path.hasPrefix(root.path + "/staging/")
        else {
            throw BackupError.destinationUnavailable
        }

        // Preflight: library must be current, stable and not mid-operation.
        guard StorageService.migrationPreflight(configuration: configuration) == .current else {
            throw BackupError.libraryUnavailable
        }
        let nonterminal = try await metadataExporter.nonterminalGenerationCount()
        guard nonterminal == 0 else { throw BackupError.nonterminalGeneration }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationParent.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BackupError.destinationUnavailable
        }
        let staging = BackupPackageStorage.temporaryStagingURL(destination: destination)
        defer {
            if FileManager.default.fileExists(atPath: staging.path) {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        try BackupPackageStorage.createStagingDirectory(at: staging)

        // Snapshot A.
        progress(.exportingMetadata)
        let recordsA = try await metadataExporter.exportRecords()
        let recordsDataA = try BackupJSON.deterministicData(recordsA)
        let digestA = SHA256Digest.of(recordsDataA)

        // Collect assets referenced by snapshot A and verify they all exist.
        let referencedAssets = try Self.collectAssets(from: recordsA)
        try await verifyAllAssetsExist(referencedAssets)

        // Copy assets first so the manifest can carry the real byte totals.
        progress(.copyingAssets)
        var assetDigests: [BackupAssetDigest] = []
        for resourceID in referencedAssets.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            let destinationURL = staging.appendingPathComponent(BackupPackageLayout.assetRelativePath(resourceID))
            let digest = try await assetReader.copyAssetToBackup(resourceID, to: destinationURL)
            assetDigests.append(BackupAssetDigest(resourceID: resourceID, digest: digest))
        }

        var totalAssetBytes: Int64 = 0
        for asset in assetDigests {
            totalAssetBytes = BackupSafeMath.add(totalAssetBytes, asset.digest.byteCount)
        }

        let sourceManifest = try await assetReader.libraryManifest()
        let manifest = try makeManifest(
            records: recordsA,
            assetCount: referencedAssets.count,
            totalAssetBytes: totalAssetBytes,
            sourceManifest: sourceManifest
        )

        try writeJSON(manifest, to: staging.appendingPathComponent(BackupPackageLayout.manifestFileName))
        try recordsDataA.write(to: staging.appendingPathComponent(BackupPackageLayout.recordsRelativePath), options: [.atomic])

        // Checksums for manifest, records and all assets.
        progress(.verifying)
        var checksumEntries: [BackupChecksumEntry] = []
        for relativePath in [
            BackupPackageLayout.manifestFileName,
            BackupPackageLayout.recordsRelativePath,
        ] {
            let url = staging.appendingPathComponent(relativePath)
            let digest = try BackupChecksum.digest(of: url)
            checksumEntries.append(BackupChecksumEntry(relativePath: relativePath, byteCount: digest.byteCount, sha256: digest.sha256))
        }
        for asset in assetDigests {
            checksumEntries.append(BackupChecksumEntry(
                relativePath: BackupPackageLayout.assetRelativePath(asset.resourceID),
                byteCount: asset.digest.byteCount,
                sha256: asset.digest.sha256
            ))
        }
        try writeJSON(BackupChecksumManifest(entries: checksumEntries), to: staging.appendingPathComponent(BackupPackageLayout.checksumsFileName))

        // Stability fence: the library must be unchanged between snapshot A and B.
        let recordsB = try await metadataExporter.exportRecords()
        let recordsDataB = try BackupJSON.deterministicData(recordsB)
        guard digestA == SHA256Digest.of(recordsDataB) else {
            throw BackupError.libraryChangedDuringBackup
        }

        // Self-validation with the same validator restore will use.
        _ = try BackupValidator().validate(packageURL: staging)

        // Disk space before publishing.
        progress(.publishing)
        let available = try capacity.availableBytes(at: destinationParent)
        let stagingBytes = try BackupFileSize.bytes(in: staging)
        let existingDestinationBytes = try existingBytes(at: destination)
        let required = BackupCapacityRequirement.backupRequiredBytes(
            packageBytes: stagingBytes,
            existingDestinationBytes: existingDestinationBytes
        )
        guard available >= required else {
            throw BackupError.insufficientSpace(required: required, available: available)
        }

        try BackupPackageStorage.publish(stagingURL: staging, destination: destination)

        let unreferencedCount = try countUnreferencedFiles(referencedAssets)
        return BackupSummary(
            backupID: manifest.backupID,
            createdAt: manifest.createdAt,
            recordCounts: manifest.recordCounts,
            assetCount: manifest.assetCount,
            totalAssetBytes: manifest.totalAssetBytes,
            formatVersion: manifest.backupFormatVersion,
            schemaVersion: manifest.schemaVersion,
            storageLayoutVersion: manifest.storageLayoutVersion,
            unreferencedFileCount: unreferencedCount
        )
    }

    // MARK: - Private

    private func makeManifest(
        records: BackupRecordsV1,
        assetCount: Int,
        totalAssetBytes: Int64,
        sourceManifest: StorageLibraryManifest
    ) throws -> BackupManifest {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return BackupManifest(
            backupFormatVersion: BackupFormat.version,
            backupID: UUID(),
            createdAt: .now,
            applicationVersion: version,
            applicationBuild: build,
            sourceLibraryID: sourceManifest.libraryID,
            sourceLibraryCreatedAt: sourceManifest.createdAt,
            schemaVersion: BackupVersion.string(schemaVersion: WardrobeSchemaV1.versionIdentifier),
            storageLayoutVersion: StorageConfiguration.layoutVersion,
            recordCounts: BackupRecordCounts(records: records),
            assetCount: assetCount,
            totalAssetBytes: totalAssetBytes
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try BackupJSON.deterministicData(value)
        try data.write(to: url, options: [.atomic])
    }

    private func verifyAllAssetsExist(_ assets: Set<StorageResourceID>) async throws {
        for resourceID in assets {
            try Task.checkCancellation()
            let exists = try await assetReader.exists(resourceID)
            guard exists else {
                throw BackupError.missingAsset(resource: resourceID.rawValue)
            }
        }
    }

    private func existingBytes(at destination: URL) throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) else { return 0 }
        if isDirectory.boolValue {
            return try BackupFileSize.bytes(in: destination)
        }
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func countUnreferencedFiles(_ referencedAssets: Set<StorageResourceID>) throws -> Int {
        let referencedPaths = Set(referencedAssets.map { $0.rawValue })
        var count = 0
        for kind in StorageOwnerKind.allCases {
            let directory = configuration.rootURL.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let relative = String(
                BackupPathResolver.realPath(fileURL.path)
                    .dropFirst(BackupPathResolver.realPath(configuration.rootURL.path).count + 1)
            )
            if !referencedPaths.contains(relative) { count += 1 }
        }
        }
        return count
    }

    private static func collectAssets(from records: BackupRecordsV1) throws -> Set<StorageResourceID> {
        var result = Set<StorageResourceID>()
        func insert(_ rawValue: String, recordID: UUID?) throws {
            guard let id = try? StorageResourceID(rawValue: rawValue) else {
                throw BackupError.invalidResourceID(resource: rawValue, recordID: recordID)
            }
            result.insert(id)
        }
        for item in records.clothingItems {
            try insert(item.originalResourceID, recordID: item.id)
            if let value = item.processedResourceID { try insert(value, recordID: item.id) }
            if let value = item.thumbnailResourceID { try insert(value, recordID: item.id) }
        }
        for image in records.personImages {
            try insert(image.originalResourceID, recordID: image.id)
            if let value = image.processedResourceID { try insert(value, recordID: image.id) }
            if let value = image.thumbnailResourceID { try insert(value, recordID: image.id) }
        }
        for outfit in records.outfits {
            if let value = outfit.coverResourceID { try insert(value, recordID: outfit.id) }
        }
        for item in records.outfitItems {
            if let value = item.thumbnailResourceIDSnapshot { try insert(value, recordID: item.id) }
        }
        for generation in records.generations {
            if let value = generation.resultResourceID { try insert(value, recordID: generation.id) }
            if let value = generation.resultThumbnailResourceID { try insert(value, recordID: generation.id) }
        }
        for input in records.generationPersonInputs {
            try insert(input.resourceIDSnapshot, recordID: input.id)
        }
        for input in records.generationGarmentInputs {
            try insert(input.resourceIDSnapshot, recordID: input.id)
        }
        return result
    }
}

private enum SHA256Digest {
    static func of(_ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().hexString
    }
}
