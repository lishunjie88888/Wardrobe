import Foundation

struct BackupValidationResult: Equatable, Sendable {
    let manifest: BackupManifest
    let records: BackupRecordsV1
    let checksums: [BackupChecksumEntry]
    let referencedAssets: Set<StorageResourceID>
    let totalAssetBytes: Int64
}

/// Single source of truth for package integrity. The exporter validates its
/// own output with this same validator before publishing, and restore refuses
/// any package that does not pass.
struct BackupValidator {
    // MARK: - Package Validation

    func validate(packageURL: URL) throws -> BackupValidationResult {
        try Task.checkCancellation()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BackupError.notADirectory
        }
        let package = packageURL.standardizedFileURL
        try BackupPackageStorage.validateNoSymbolicLink(at: package)

        let manifestURL = try requiredFile(package, BackupPackageLayout.manifestFileName)
        let recordsURL = try requiredFile(package, BackupPackageLayout.recordsRelativePath)
        let checksumsURL = try requiredFile(package, BackupPackageLayout.checksumsFileName)

        // Path safety: walk the whole package, reject escapes/symlinks/unknown files.
        let (foundFiles, foundDirectories) = try walkPackage(package)

        let checksums: [BackupChecksumEntry]
        do {
            let decoded = try BackupJSON.decoder().decode(
                BackupChecksumManifest.self,
                from: Data(contentsOf: checksumsURL)
            )
            checksums = decoded.entries.sorted()
        } catch {
            throw BackupError.invalidChecksumManifest
        }
        try validateChecksumManifestShape(checksums, foundFiles: foundFiles)

        // Integrity first: every declared checksum must match the actual bytes
        // before any JSON is trusted. This catches tampered records, assets or
        // the manifest itself with a precise path instead of a parse failure.
        var totalAssetBytes: Int64 = 0
        for entry in checksums {
            guard let url = BackupPackageLayout.resolvedURL(in: package, relativePath: entry.relativePath) else {
                throw BackupError.unsafePath(entry.relativePath)
            }
            guard foundFiles.contains(entry.relativePath) else {
                throw BackupError.missingAsset(resource: entry.relativePath)
            }
            let digest = try BackupChecksum.digest(of: url)
            guard digest.byteCount == entry.byteCount, digest.sha256 == entry.sha256 else {
                throw BackupError.checksumMismatch(path: entry.relativePath)
            }
            if entry.relativePath.hasPrefix("\(BackupPackageLayout.assetsDirectory)/") {
                totalAssetBytes = BackupSafeMath.add(totalAssetBytes, entry.byteCount)
            }
        }

        let manifest: BackupManifest
        do {
            manifest = try BackupJSON.decoder().decode(
                BackupManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw BackupError.invalidManifest
        }
        try validateCompatibility(manifest)

        let records: BackupRecordsV1
        do {
            records = try BackupJSON.decoder().decode(
                BackupRecordsV1.self,
                from: Data(contentsOf: recordsURL)
            )
        } catch {
            throw BackupError.invalidRecords
        }

        // Cross-check manifest counts against the parsed records.
        let actualCounts = BackupRecordCounts(records: records)
        guard actualCounts == manifest.recordCounts else {
            throw BackupError.invalidRecords
        }

        try validateUUIDUniqueness(records)
        try validateRelationships(records)

        let referencedAssets = try collectResourceIDs(records)
        guard referencedAssets.count == manifest.assetCount else {
            throw BackupError.invalidManifest
        }

        // Every referenced asset must be present as a package file with a checksum.
        let assetPaths = Set(referencedAssets.map(BackupPackageLayout.assetRelativePath))
        guard assetPaths.isSubset(of: foundFiles) else {
            throw BackupError.missingAsset(resource: "assets")
        }
        let checksumPaths = Set(checksums.map(\.relativePath))
        guard assetPaths.isSubset(of: checksumPaths) else {
            throw BackupError.invalidChecksumManifest
        }

        guard totalAssetBytes == manifest.totalAssetBytes else {
            throw BackupError.invalidManifest
        }
        _ = foundDirectories
        return BackupValidationResult(
            manifest: manifest,
            records: records,
            checksums: checksums,
            referencedAssets: referencedAssets,
            totalAssetBytes: totalAssetBytes
        )
    }

    // MARK: - Compatibility (shared Stage 13 source of truth)

    func validateCompatibility(_ manifest: BackupManifest) throws {
        guard manifest.backupFormatVersion == BackupFormat.version else {
            throw BackupError.unsupportedBackupFormat(found: manifest.backupFormatVersion)
        }
        guard manifest.storageLayoutVersion == StorageConfiguration.layoutVersion else {
            throw BackupError.unsupportedStorageLayout(manifest.storageLayoutVersion)
        }
        guard BackupVersion.isCurrentSchema(manifest.schemaVersion) else {
            throw BackupError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
    }

    // MARK: - Private

    private func requiredFile(_ package: URL, _ relativePath: String) throws -> URL {
        guard BackupPackageLayout.validateRelativePath(relativePath),
              let url = BackupPackageLayout.resolvedURL(in: package, relativePath: relativePath) else {
            throw BackupError.unsafePath(relativePath)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BackupError.missingAsset(resource: relativePath)
        }
        return url
    }

    private func walkPackage(_ package: URL) throws -> (files: Set<String>, directories: [String]) {
        var files = Set<String>()
        var directories: [String] = []
        // The enumerator resolves symlinked path components (e.g. /tmp ->
        // /private/tmp), so the package prefix must be resolved the same way
        // before computing relative paths.
        let packagePath = BackupPathResolver.realPath(package.path)
        guard let enumerator = FileManager.default.enumerator(
            at: package,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw BackupError.invalidManifest
        }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw BackupError.symbolicLink(url.lastPathComponent)
            }
            let relative = String(BackupPathResolver.realPath(url.path).dropFirst(packagePath.count + 1))
            guard BackupPackageLayout.validateRelativePath(relative) else {
                throw BackupError.unsafePath(relative)
            }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                directories.append(relative)
                continue
            }
            guard BackupPackageLayout.isAllowedPackagePath(relative)
                    || BackupFormat.allowedExtraFiles.contains(url.lastPathComponent) else {
                throw BackupError.unsafePath(relative)
            }
            files.insert(relative)
        }
        return (files, directories)
    }

    private func validateChecksumManifestShape(
        _ checksums: [BackupChecksumEntry],
        foundFiles: Set<String>
    ) throws {
        guard Set(checksums.map(\.relativePath)).count == checksums.count else {
            throw BackupError.invalidChecksumManifest
        }
        // The checksum manifest cannot vouch for its own bytes.
        guard !checksums.contains(where: { $0.relativePath == BackupPackageLayout.checksumsFileName }) else {
            throw BackupError.invalidChecksumManifest
        }
        let required = Set([
            BackupPackageLayout.manifestFileName,
            BackupPackageLayout.recordsRelativePath,
        ])
        guard required.isSubset(of: checksums.map(\.relativePath)) else {
            throw BackupError.invalidChecksumManifest
        }
        for entry in checksums {
            guard BackupPackageLayout.validateRelativePath(entry.relativePath),
                  entry.byteCount >= 0
            else {
                throw BackupError.unsafePath(entry.relativePath)
            }
            guard foundFiles.contains(entry.relativePath) else {
                throw BackupError.invalidChecksumManifest
            }
        }
        let extraDeclared = Set(checksums.map(\.relativePath)).subtracting(foundFiles)
        guard extraDeclared.isEmpty else {
            throw BackupError.invalidChecksumManifest
        }
    }

    private func validateUUIDUniqueness(_ records: BackupRecordsV1) throws {
        func check<T: Identifiable>(_ items: [T], entity: String) throws where T.ID == UUID {
            var seen = Set<UUID>()
            for item in items {
                guard seen.insert(item.id).inserted else {
                    throw BackupError.duplicateRecordID(entity: entity, id: item.id)
                }
            }
        }
        try check(records.clothingItems, entity: "ClothingItem")
        try check(records.personProfiles, entity: "PersonProfile")
        try check(records.personImages, entity: "PersonImage")
        try check(records.outfits, entity: "Outfit")
        try check(records.outfitItems, entity: "OutfitItem")
        try check(records.generations, entity: "GenerationRecord")
        try check(records.generationPersonInputs, entity: "GenerationPersonInput")
        try check(records.generationGarmentInputs, entity: "GenerationGarmentInput")

        let allIDs = records.clothingItems.map(\.id) + records.personProfiles.map(\.id)
            + records.personImages.map(\.id) + records.outfits.map(\.id)
            + records.outfitItems.map(\.id) + records.generations.map(\.id)
            + records.generationPersonInputs.map(\.id) + records.generationGarmentInputs.map(\.id)
        var seen = Set<UUID>()
        for id in allIDs where !seen.insert(id).inserted {
            throw BackupError.duplicateRecordID(entity: "global", id: id)
        }
    }

    private func validateRelationships(_ records: BackupRecordsV1) throws {
        let clothingIDs = Set(records.clothingItems.map(\.id))
        let profileIDs = Set(records.personProfiles.map(\.id))
        let imageIDs = Set(records.personImages.map(\.id))
        let outfitIDs = Set(records.outfits.map(\.id))
        let generationIDs = Set(records.generations.map(\.id))

        for image in records.personImages where !profileIDs.contains(image.profileID) {
            throw BackupError.brokenRelationship(entity: "PersonImage", id: image.id)
        }
        for item in records.outfitItems {
            if !outfitIDs.contains(item.outfitID) {
                throw BackupError.brokenRelationship(entity: "OutfitItem", id: item.id)
            }
            if let relationID = item.clothingItemRelationID, !clothingIDs.contains(relationID) {
                throw BackupError.brokenRelationship(entity: "OutfitItem", id: item.id)
            }
        }
        for input in records.generationPersonInputs {
            if !generationIDs.contains(input.generationID) {
                throw BackupError.brokenRelationship(entity: "GenerationPersonInput", id: input.id)
            }
            if let relationID = input.personProfileRelationID, !profileIDs.contains(relationID) {
                throw BackupError.brokenRelationship(entity: "GenerationPersonInput", id: input.id)
            }
            if let relationID = input.personImageRelationID, !imageIDs.contains(relationID) {
                throw BackupError.brokenRelationship(entity: "GenerationPersonInput", id: input.id)
            }
        }
        for input in records.generationGarmentInputs {
            if !generationIDs.contains(input.generationID) {
                throw BackupError.brokenRelationship(entity: "GenerationGarmentInput", id: input.id)
            }
            if let relationID = input.clothingItemRelationID, !clothingIDs.contains(relationID) {
                throw BackupError.brokenRelationship(entity: "GenerationGarmentInput", id: input.id)
            }
        }
    }

    private func collectResourceIDs(_ records: BackupRecordsV1) throws -> Set<StorageResourceID> {
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
