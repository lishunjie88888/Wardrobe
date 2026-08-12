import Foundation
import SwiftData
import XCTest
@testable import Wardrobe

private struct FakeCapacity: BackupCapacityChecking {
    let available: Int64
    func availableBytes(at url: URL) throws -> Int64 { available }
}

@MainActor
final class Stage14BackupRestoreTests: XCTestCase {
    private let fm = FileManager.default

    // MARK: - Helpers

    private func makeRoot(_ name: String) throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("WardrobeStage14Tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("library", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            if fm.fileExists(atPath: base.path) {
                try fm.removeItem(at: base)
            }
        }
        return root
    }

    private func makeLibrary(root: URL) throws -> (StorageService, ModelContainer) {
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
        let container = try WardrobeModelContainerFactory.production(
            databaseDirectory: root.appendingPathComponent("database", isDirectory: true)
        )
        return (storage, container)
    }

    private func makeExporter(
        root: URL,
        container: ModelContainer,
        capacity: any BackupCapacityChecking = FakeCapacity(available: Int64.max)
    ) -> BackupExporter {
        BackupExporter(
            configuration: StorageConfiguration(rootURL: root),
            metadataExporter: SwiftDataBackupMetadataExporter(container: container),
            assetReader: try! StorageService(configuration: StorageConfiguration(rootURL: root)),
            capacity: capacity
        )
    }

    private func makeRestoreCoordinator(
        root: URL,
        capacity: any BackupCapacityChecking = FakeCapacity(available: Int64.max)
    ) -> LibraryRestoreCoordinator {
        LibraryRestoreCoordinator(
            configuration: StorageConfiguration(rootURL: root),
            capacity: capacity
        )
    }

    private func applyRestore(to root: URL) throws -> RestoreBootstrapOutcome {
        try LibraryRestoreBootstrap.applyPendingRestore(
            configuration: StorageConfiguration(rootURL: root)
        )
    }

    private func assetData(_ label: String, size: Int = 0) -> Data {
        let base = Data(("wardrobe-stage14-asset-\(label)".utf8))
        guard size > 0 else { return base }
        guard size > base.count else { return Data(base.prefix(size)) }
        var data = base
        let pattern = UInt8(truncatingIfNeeded: data.count)
        data.append(contentsOf: [UInt8](repeating: pattern, count: size - data.count))
        return data
    }

    /// Creates a small pre-existing library at the restore target so the
    /// replacement/rollback flows match production. The container is released
    /// before returning so the root can be moved by the restore transaction.
    private func makeOriginalLibrary(root: URL, name: String = "Original") async throws -> Data {
        let (storage, container) = try makeLibrary(root: root)
        try await storage.write(
            assetData("original-\(name)"),
            to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg"))
        )
        let context = ModelContext(container)
        context.insert(ClothingItem(
            id: Self.id(1),
            name: name,
            originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))
        ))
        try context.save()
        return try await storage.read(try StorageResourceID(rawValue: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
    }

    private func rechecksum(package: URL) throws {
        var entries: [BackupChecksumEntry] = []
        guard let enumerator = fm.enumerator(
            at: package,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { throw BackupError.invalidChecksumManifest }
        for case let url as URL in enumerator {
            guard url.lastPathComponent != BackupPackageLayout.checksumsFileName else { continue }
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else { continue }
            let relative = String(
                BackupPathResolver.realPath(url.path)
                    .dropFirst(BackupPathResolver.realPath(package.path).count + 1)
            )
            let digest = try BackupChecksum.digest(of: url)
            entries.append(BackupChecksumEntry(relativePath: relative, byteCount: digest.byteCount, sha256: digest.sha256))
        }
        let data = try BackupJSON.deterministicData(BackupChecksumManifest(entries: entries))
        try data.write(to: package.appendingPathComponent(BackupPackageLayout.checksumsFileName), options: [.atomic])
    }

    /// Rewrites records.json and keeps the package internally consistent
    /// (manifest counts + checksums), so tests can target one validation rule.
    private func rewriteRecords(in package: URL, _ transform: (inout BackupRecordsV1) -> Void) throws {
        let recordsURL = package.appendingPathComponent(BackupPackageLayout.recordsRelativePath)
        var records = try BackupJSON.decoder().decode(
            BackupRecordsV1.self,
            from: Data(contentsOf: recordsURL)
        )
        transform(&records)
        try BackupJSON.deterministicData(records).write(to: recordsURL, options: [.atomic])
        let manifestURL = package.appendingPathComponent(BackupPackageLayout.manifestFileName)
        var manifest = try BackupJSON.decoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.recordCounts = BackupRecordCounts(records: records)
        try BackupJSON.deterministicData(manifest).write(to: manifestURL, options: [.atomic])
        try rechecksum(package: package)
    }

    private func expectBackupError<T>(
        _ expression: () throws -> T,
        _ expected: BackupError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? BackupError, expected, file: file, line: line)
        }
    }

    // MARK: - Fixture

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "14000000-0000-0000-0000-%012d", suffix))!
    }

    private static func resource(_ kind: StorageOwnerKind, _ suffix: Int, _ resourceKind: StorageResourceKind) -> String {
        try! StorageResourceID(owner: .init(kind: kind, id: id(suffix)), kind: resourceKind).rawValue
    }

    /// Builds a full 8-model fixture with real asset files, including a
    /// deleted-source garment (metadata deleted, files kept) whose processed
    /// image is still referenced by a generation snapshot.
    private func buildFullFixture(container: ModelContainer, storage: StorageService) async throws {
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let assets: [(String, String)] = [
            (Self.resource(.garment, 1, .original(fileExtension: "jpg")), "g1-original"),
            (Self.resource(.garment, 1, .processed), "g1-processed"),
            (Self.resource(.garment, 1, .thumbnail), "g1-thumb"),
            (Self.resource(.garment, 2, .original(fileExtension: "png")), "g2-original"),
            (Self.resource(.garment, 2, .processed), "g2-processed"),
            (Self.resource(.garment, 2, .thumbnail), "g2-thumb"),
            (Self.resource(.garment, 3, .original(fileExtension: "png")), "g3-original"),
            (Self.resource(.garment, 3, .thumbnail), "g3-thumb"),
            (Self.resource(.garment, 70, .original(fileExtension: "jpg")), "g70-original"),
            (Self.resource(.garment, 70, .processed), "g70-processed"),
            (Self.resource(.garment, 70, .thumbnail), "g70-thumb"),
            (Self.resource(.person, 20, .original(fileExtension: "jpg")), "p20-original"),
            (Self.resource(.person, 20, .processed), "p20-processed"),
            (Self.resource(.person, 20, .thumbnail), "p20-thumb"),
            (Self.resource(.person, 21, .original(fileExtension: "jpg")), "p21-original"),
            (Self.resource(.person, 22, .original(fileExtension: "jpg")), "p22-original"),
            (Self.resource(.person, 22, .thumbnail), "p22-thumb"),
            (Self.resource(.generation, 40, .generationResult(fileExtension: "png")), "gen40-result"),
            (Self.resource(.generation, 40, .thumbnail), "gen40-thumb"),
            (Self.resource(.outfit, 30, .outfitCover), "outfit30-cover"),
        ]
        for (rawValue, label) in assets {
            try await storage.write(assetData(label), to: try StorageResourceID(rawValue: rawValue))
        }

        let coat = ClothingItem(id: Self.id(1), name: "Future coat", notes: nil, categoryCode: "future-category", brand: "Archive Brand", colorCodes: ["black"], seasonCodes: ["winter"], styleCodes: [], materials: ["wool"], tags: ["archive"], isFavorite: true, originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg")), processedResourceID: Self.resource(.garment, 1, .processed), thumbnailResourceID: Self.resource(.garment, 1, .thumbnail), archivedAt: date, createdAt: date)
        let top = ClothingItem(id: Self.id(2), name: "Top", categoryCode: ClothingCategory.tops.rawValue, originalResourceID: Self.resource(.garment, 2, .original(fileExtension: "png")), processedResourceID: Self.resource(.garment, 2, .processed), thumbnailResourceID: Self.resource(.garment, 2, .thumbnail), createdAt: date.addingTimeInterval(1))
        let watch = ClothingItem(id: Self.id(3), name: "Watch", categoryCode: ClothingCategory.accessories.rawValue, originalResourceID: Self.resource(.garment, 3, .original(fileExtension: "png")), thumbnailResourceID: Self.resource(.garment, 3, .thumbnail), createdAt: date.addingTimeInterval(2))
        let deletedCoat = ClothingItem(id: Self.id(70), name: "Deleted coat", categoryCode: ClothingCategory.outerwear.rawValue, originalResourceID: Self.resource(.garment, 70, .original(fileExtension: "jpg")), processedResourceID: Self.resource(.garment, 70, .processed), thumbnailResourceID: Self.resource(.garment, 70, .thumbnail), createdAt: date)

        let active = PersonProfile(id: Self.id(10), name: "Default", notes: "notes", isDefault: true, createdAt: date)
        let archived = PersonProfile(id: Self.id(11), name: "Archived", archivedAt: date, createdAt: date)
        let primary = PersonImage(id: Self.id(20), profile: active, isPrimary: true, originalResourceID: Self.resource(.person, 20, .original(fileExtension: "jpg")), processedResourceID: Self.resource(.person, 20, .processed), thumbnailResourceID: Self.resource(.person, 20, .thumbnail), pixelWidth: 1200, pixelHeight: 1600, createdAt: date)
        let additional = PersonImage(id: Self.id(21), profile: active, originalResourceID: Self.resource(.person, 21, .original(fileExtension: "jpg")), createdAt: date.addingTimeInterval(1))
        let archivedImage = PersonImage(id: Self.id(22), profile: archived, isPrimary: true, originalResourceID: Self.resource(.person, 22, .original(fileExtension: "jpg")), thumbnailResourceID: Self.resource(.person, 22, .thumbnail), createdAt: date)

        let outfit = Outfit(id: Self.id(30), name: "Fixture Outfit", notes: "stable", isFavorite: true, coverResourceID: Self.resource(.outfit, 30, .outfitCover), archivedAt: nil, createdAt: date)
        outfit.items = [
            OutfitItem(id: Self.id(31), outfit: outfit, clothingItem: coat, clothingItemID: coat.id, clothingNameSnapshot: coat.name, thumbnailResourceIDSnapshot: coat.thumbnailResourceID, slotCode: "future-slot", sortOrder: 0, createdAt: date),
            OutfitItem(id: Self.id(32), outfit: outfit, clothingItem: top, clothingItemID: top.id, clothingNameSnapshot: top.name, thumbnailResourceIDSnapshot: top.thumbnailResourceID, slotCode: TryOnSlot.upperBody.rawValue, sortOrder: 0, createdAt: date),
            OutfitItem(id: Self.id(33), outfit: outfit, clothingItem: nil, clothingItemID: Self.id(333), clothingNameSnapshot: "Deleted scarf", thumbnailResourceIDSnapshot: Self.resource(.garment, 3, .thumbnail), slotCode: TryOnSlot.accessories.rawValue, sortOrder: 0, createdAt: date),
            OutfitItem(id: Self.id(34), outfit: outfit, clothingItem: watch, clothingItemID: watch.id, clothingNameSnapshot: watch.name, thumbnailResourceIDSnapshot: watch.thumbnailResourceID, slotCode: TryOnSlot.accessories.rawValue, sortOrder: 1, createdAt: date),
        ]

        let succeeded = GenerationRecord(id: Self.id(40), providerID: "mock", providerModelID: "fixture", statusCode: GenerationStatus.succeeded.rawValue, prompt: "prompt", optionsJSON: "{\"seed\":1}", resultResourceID: Self.resource(.generation, 40, .generationResult(fileExtension: "png")), resultThumbnailResourceID: Self.resource(.generation, 40, .thumbnail), attemptCount: 1, startedAt: date, completedAt: date.addingTimeInterval(2), createdAt: date)
        let failed = GenerationRecord(id: Self.id(41), sourceGenerationID: Self.id(40), providerID: "future-provider", statusCode: "future-status", prompt: "failed", optionsJSON: "{}", errorCode: "fixture", errorMessage: "safe", attemptCount: 1, startedAt: date, completedAt: date.addingTimeInterval(3), createdAt: date)
        let cancelled = GenerationRecord(id: Self.id(42), providerID: "external-chatgpt-manual", statusCode: GenerationStatus.cancelled.rawValue, prompt: "cancelled", optionsJSON: "{}", createdAt: date)

        succeeded.personInputs = [GenerationPersonInput(id: Self.id(50), generation: succeeded, personProfile: active, personProfileID: active.id, personNameSnapshot: active.name, personImage: primary, personImageID: primary.id, resourceIDSnapshot: primary.processedResourceID!, sortOrder: 0, createdAt: date)]
        succeeded.garmentInputs = [GenerationGarmentInput(id: Self.id(60), generation: succeeded, clothingItem: coat, clothingItemID: coat.id, clothingNameSnapshot: coat.name, categoryCodeSnapshot: coat.categoryCode, slotCode: "future-slot", resourceIDSnapshot: coat.processedResourceID!, sortOrder: 0, createdAt: date)]
        failed.personInputs = [GenerationPersonInput(id: Self.id(51), generation: failed, personProfile: nil, personProfileID: Self.id(111), personNameSnapshot: "Deleted person", personImage: nil, personImageID: Self.id(211), resourceIDSnapshot: Self.resource(.person, 21, .original(fileExtension: "jpg")), sortOrder: 0, createdAt: date)]
        failed.garmentInputs = [GenerationGarmentInput(id: Self.id(61), generation: failed, clothingItem: nil, clothingItemID: Self.id(70), clothingNameSnapshot: "Deleted coat", categoryCodeSnapshot: "future-category", slotCode: TryOnSlot.upperBody.rawValue, resourceIDSnapshot: Self.resource(.garment, 70, .processed), sortOrder: 0, createdAt: date)]
        cancelled.personInputs = [GenerationPersonInput(id: Self.id(52), generation: cancelled, personProfile: active, personProfileID: active.id, personNameSnapshot: active.name, personImage: additional, personImageID: additional.id, resourceIDSnapshot: Self.resource(.person, 21, .original(fileExtension: "jpg")), sortOrder: 0, createdAt: date)]
        cancelled.garmentInputs = [GenerationGarmentInput(id: Self.id(62), generation: cancelled, clothingItem: watch, clothingItemID: watch.id, clothingNameSnapshot: watch.name, categoryCodeSnapshot: watch.categoryCode, slotCode: TryOnSlot.accessories.rawValue, resourceIDSnapshot: Self.resource(.garment, 3, .original(fileExtension: "png")), sortOrder: 0, createdAt: date)]

        context.insert(coat)
        context.insert(top)
        context.insert(watch)
        context.insert(deletedCoat)
        context.insert(active)
        context.insert(archived)
        context.insert(primary)
        context.insert(additional)
        context.insert(archivedImage)
        context.insert(outfit)
        context.insert(succeeded)
        context.insert(failed)
        context.insert(cancelled)
        try context.save()

        // Delete the coat's metadata only; its files stay and are still
        // referenced by the failed generation's garment snapshot.
        context.delete(deletedCoat)
        try context.save()
    }

    private func exportBackup(
        from root: URL,
        container: ModelContainer,
        to destination: URL,
        capacity: any BackupCapacityChecking = FakeCapacity(available: Int64.max)
    ) async throws -> BackupSummary {
        try await makeExporter(root: root, container: container, capacity: capacity).createBackup(destination: destination)
    }

    // MARK: - Round Trip

    func testFullRoundTripRestoresAllEightModelsToDifferentRoot() async throws {
        let sourceRoot = try makeRoot("source-a")
        let restoredRoot = try makeRoot("restored-b")
        let (sourceStorage, sourceContainer) = try makeLibrary(root: sourceRoot)
        try await buildFullFixture(container: sourceContainer, storage: sourceStorage)
        let sourceManifest = try await sourceStorage.libraryManifest()
        _ = try await makeOriginalLibrary(root: restoredRoot, name: "Pre-restore")

        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("RoundTrip.\(BackupFormat.packageExtension)")
        let summary = try await exportBackup(from: sourceRoot, container: sourceContainer, to: packageURL)
        XCTAssertEqual(summary.recordCounts, BackupRecordCounts(
            clothingItems: 3, personProfiles: 2, personImages: 3,
            outfits: 1, outfitItems: 4, generations: 3,
            generationPersonInputs: 3, generationGarmentInputs: 3
        ))
        XCTAssertEqual(summary.assetCount, 18)
        XCTAssertEqual(summary.unreferencedFileCount, 2)

        _ = try BackupValidator().validate(packageURL: packageURL)
        let sourceRecords = try SwiftDataBackupMetadataExporter(container: sourceContainer).exportRecords()

        let coordinator = makeRestoreCoordinator(root: restoredRoot)
        let ready = try await coordinator.prepare(packageURL: packageURL)
        XCTAssertEqual(ready.restoredRecordCounts, sourceRecords.counts())
        XCTAssertNotEqual(sourceRoot.path, restoredRoot.path)

        let outcome = try applyRestore(to: restoredRoot)
        guard case let .completed(result) = outcome else {
            return XCTFail("Expected completed restore, got \(outcome)")
        }
        XCTAssertFalse(result.rolledBack)

        let (restoredStorage, restoredContainer) = try makeLibrary(root: restoredRoot)
        let restoredManifest = try await restoredStorage.libraryManifest()
        XCTAssertEqual(restoredManifest.libraryID, sourceManifest.libraryID)
        XCTAssertEqual(restoredManifest.createdAt, sourceManifest.createdAt)

        let restoredRecords = try SwiftDataBackupMetadataExporter(container: restoredContainer).exportRecords()
        XCTAssertEqual(restoredRecords, sourceRecords)

        let expectedAssets = sourceRecords.allResourceStrings()
        XCTAssertEqual(expectedAssets.count, 18)
        for rawValue in expectedAssets {
            let resourceID = try StorageResourceID(rawValue: rawValue)
            let restoredBytes = try await restoredStorage.read(resourceID)
            let sourceBytes = try await sourceStorage.read(resourceID)
            XCTAssertEqual(restoredBytes, sourceBytes, "asset \(rawValue)")
        }
    }

    func testDeletedSourceSnapshotResourcesIncludedAndRestored() async throws {
        let sourceRoot = try makeRoot("deleted-source")
        let restoredRoot = try makeRoot("deleted-source-b")
        let (sourceStorage, sourceContainer) = try makeLibrary(root: sourceRoot)
        try await buildFullFixture(container: sourceContainer, storage: sourceStorage)
        _ = try await makeOriginalLibrary(root: restoredRoot)

        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("DeletedSource.\(BackupFormat.packageExtension)")
        _ = try await exportBackup(from: sourceRoot, container: sourceContainer, to: packageURL)

        let coordinator = makeRestoreCoordinator(root: restoredRoot)
        _ = try await coordinator.prepare(packageURL: packageURL)
        _ = try applyRestore(to: restoredRoot)

        let (restoredStorage, restoredContainer) = try makeLibrary(root: restoredRoot)
        let records = try SwiftDataBackupMetadataExporter(container: restoredContainer).exportRecords()
        let garmentInput = try XCTUnwrap(records.generationGarmentInputs.first { $0.id == Self.id(61) })
        XCTAssertNil(garmentInput.clothingItemRelationID)
        XCTAssertEqual(garmentInput.clothingItemID, Self.id(70))
        XCTAssertEqual(garmentInput.clothingNameSnapshot, "Deleted coat")
        XCTAssertEqual(garmentInput.resourceIDSnapshot, Self.resource(.garment, 70, .processed))

        let orphanItem = try XCTUnwrap(records.outfitItems.first { $0.id == Self.id(33) })
        XCTAssertNil(orphanItem.clothingItemRelationID)
        XCTAssertEqual(orphanItem.clothingItemID, Self.id(333))
        XCTAssertEqual(orphanItem.clothingNameSnapshot, "Deleted scarf")

        let snapshotResource = try StorageResourceID(rawValue: garmentInput.resourceIDSnapshot)
        let snapshotExists = try await restoredStorage.exists(snapshotResource)
        XCTAssertTrue(snapshotExists)
        let snapshotBytes = try await restoredStorage.read(snapshotResource)
        XCTAssertEqual(snapshotBytes, assetData("g70-processed"))
        _ = sourceStorage
    }

    func testLargeAssetStreamingRoundTrip() async throws {
        let sourceRoot = try makeRoot("large-source")
        let restoredRoot = try makeRoot("large-restored")
        let (sourceStorage, sourceContainer) = try makeLibrary(root: sourceRoot)
        let context = ModelContext(sourceContainer)
        let big = assetData("big", size: 2 * BackupChecksum.chunkSize + 123)
        let resource = try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(90)), kind: .original(fileExtension: "png"))
        try await sourceStorage.write(big, to: resource)
        context.insert(ClothingItem(id: Self.id(90), name: "Big", categoryCode: ClothingCategory.other.rawValue, originalResourceID: resource.rawValue, createdAt: Date(timeIntervalSince1970: 1)))
        try context.save()
        _ = try await makeOriginalLibrary(root: restoredRoot)

        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Large.\(BackupFormat.packageExtension)")
        _ = try await exportBackup(from: sourceRoot, container: sourceContainer, to: packageURL)

        let coordinator = makeRestoreCoordinator(root: restoredRoot)
        _ = try await coordinator.prepare(packageURL: packageURL)
        _ = try applyRestore(to: restoredRoot)

        let (restoredStorage, _) = try makeLibrary(root: restoredRoot)
        let restoredBig = try await restoredStorage.read(resource)
        XCTAssertEqual(restoredBig, big)
    }

    // MARK: - Corrupt Inputs

    func testCorruptManifestVariantsAreRejected() async throws {
        let sourceRoot = try makeRoot("corrupt-source")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        try await storage.write(assetData("x"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        try context.save()

        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Corrupt.\(BackupFormat.packageExtension)")
        _ = try await exportBackup(from: sourceRoot, container: container, to: packageURL)
        let validator = BackupValidator()
        let manifestURL = packageURL.appendingPathComponent(BackupPackageLayout.manifestFileName)
        let originalManifestData = try Data(contentsOf: manifestURL)

        // Invalid JSON manifest.
        try Data("not json".utf8).write(to: manifestURL)
        try rechecksum(package: packageURL)
        expectBackupError({ try validator.validate(packageURL: packageURL) }, .invalidManifest)
        try originalManifestData.write(to: manifestURL)
        try rechecksum(package: packageURL)

        // Unsupported future format.
        var manifest = try BackupJSON.decoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.backupFormatVersion = 2
        try BackupJSON.deterministicData(manifest).write(to: manifestURL)
        try rechecksum(package: packageURL)
        expectBackupError({ try validator.validate(packageURL: packageURL) }, .unsupportedBackupFormat(found: 2))

        // Unsupported schema version.
        manifest.backupFormatVersion = 1
        manifest.schemaVersion = "2.0.0"
        try BackupJSON.deterministicData(manifest).write(to: manifestURL)
        try rechecksum(package: packageURL)
        expectBackupError({ try validator.validate(packageURL: packageURL) }, .unsupportedSchemaVersion("2.0.0"))

        // Unsupported storage layout.
        manifest.schemaVersion = BackupVersion.string(schemaVersion: WardrobeSchemaV1.versionIdentifier)
        manifest.storageLayoutVersion = 2
        try BackupJSON.deterministicData(manifest).write(to: manifestURL)
        try rechecksum(package: packageURL)
        expectBackupError({ try validator.validate(packageURL: packageURL) }, .unsupportedStorageLayout(2))
    }

    func testChecksumCorruptionRejectedForAssetAndRecords() async throws {
        let sourceRoot = try makeRoot("checksum-source")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        let resourceID = try StorageResourceID(rawValue: Self.resource(.garment, 1, .original(fileExtension: "jpg")))
        try await storage.write(assetData("g1"), to: resourceID)
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        try context.save()
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Checksum.\(BackupFormat.packageExtension)")
        _ = try await exportBackup(from: sourceRoot, container: container, to: packageURL)
        let validator = BackupValidator()

        // Corrupt one asset byte.
        let assetURL = packageURL.appendingPathComponent(BackupPackageLayout.assetRelativePath(resourceID))
        var bytes = try Data(contentsOf: assetURL)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: assetURL)
        XCTAssertThrowsError(try validator.validate(packageURL: packageURL)) { error in
            guard case let .checksumMismatch(path) = error as? BackupError else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(path, BackupPackageLayout.assetRelativePath(resourceID))
        }
        try rechecksum(package: packageURL)

        // Corrupt records.json.
        let recordsURL = packageURL.appendingPathComponent(BackupPackageLayout.recordsRelativePath)
        var recordsData = try Data(contentsOf: recordsURL)
        recordsData[0] ^= 0xFF
        try recordsData.write(to: recordsURL)
        XCTAssertThrowsError(try validator.validate(packageURL: packageURL)) { error in
            guard case let .checksumMismatch(path) = error as? BackupError else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(path, BackupPackageLayout.recordsRelativePath)
        }
    }

    func testMissingReferencedAssetRejected() async throws {
        let sourceRoot = try makeRoot("missing-asset")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        let resourceID = try StorageResourceID(rawValue: Self.resource(.garment, 1, .original(fileExtension: "jpg")))
        try await storage.write(assetData("g1"), to: resourceID)
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        try context.save()
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Missing.\(BackupFormat.packageExtension)")
        _ = try await exportBackup(from: sourceRoot, container: container, to: packageURL)

        let assetURL = packageURL.appendingPathComponent(BackupPackageLayout.assetRelativePath(resourceID))
        try fm.removeItem(at: assetURL)
        expectBackupError({ try BackupValidator().validate(packageURL: packageURL) }, .invalidChecksumManifest)
    }

    func testPathTraversalAndSymlinkRejected() async throws {
        let sourceRoot = try makeRoot("traversal-source")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        try context.save()
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Traversal.\(BackupFormat.packageExtension)")
        _ = try await exportBackup(from: sourceRoot, container: container, to: packageURL)

        // A declared checksum path that escapes the package.
        var checksums = try BackupJSON.decoder().decode(BackupChecksumManifest.self, from: Data(contentsOf: packageURL.appendingPathComponent(BackupPackageLayout.checksumsFileName)))
        checksums.entries.append(BackupChecksumEntry(relativePath: "../evil", byteCount: 0, sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
        try BackupJSON.deterministicData(checksums).write(to: packageURL.appendingPathComponent(BackupPackageLayout.checksumsFileName))
        expectBackupError({ try BackupValidator().validate(packageURL: packageURL) }, .unsafePath("../evil"))
        try rechecksum(package: packageURL)

        // A symlink inside the package assets.
        let outside = backupDir.appendingPathComponent("outside-secret.txt")
        try Data("secret".utf8).write(to: outside)
        let symlink = packageURL.appendingPathComponent("assets/garments/evil.jpg")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: outside)
        expectBackupError({ try BackupValidator().validate(packageURL: packageURL) }, .symbolicLink("evil.jpg"))
    }

    func testDuplicateUUIDAndBrokenRelationshipRejected() async throws {
        let sourceRoot = try makeRoot("duplicate-source")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
        try await storage.write(assetData("p20"), to: try StorageResourceID(owner: StorageOwner(kind: .person, id: Self.id(20)), kind: .original(fileExtension: "jpg")))
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        let profile = PersonProfile(id: Self.id(10), name: "P")
        let image = PersonImage(id: Self.id(20), profile: profile, originalResourceID: Self.resource(.person, 20, .original(fileExtension: "jpg")))
        context.insert(profile)
        context.insert(image)
        try context.save()
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Duplicate.\(BackupFormat.packageExtension)")
        _ = try await exportBackup(from: sourceRoot, container: container, to: packageURL)

        try rewriteRecords(in: packageURL) { records in
            records.clothingItems.append(records.clothingItems[0])
        }
        expectBackupError({ try BackupValidator().validate(packageURL: packageURL) }, .duplicateRecordID(entity: "ClothingItem", id: Self.id(1)))

        try rewriteRecords(in: packageURL) { records in
            records.clothingItems.removeLast()
            records.personImages[0].profileID = Self.id(999)
        }
        expectBackupError({ try BackupValidator().validate(packageURL: packageURL) }, .brokenRelationship(entity: "PersonImage", id: Self.id(20)))
    }

    func testDiskFullBlocksBackupAndRestore() async throws {
        let sourceRoot = try makeRoot("diskfull-source")
        let restoredRoot = try makeRoot("diskfull-restored")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        try context.save()
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("DiskFull.\(BackupFormat.packageExtension)")

        let empty = FakeCapacity(available: 0)
        await expectBackupErrorAsync {
            _ = try await self.exportBackup(from: sourceRoot, container: container, to: packageURL, capacity: empty)
        } verifying: { error in
            guard case .insufficientSpace = error as? BackupError else {
                return XCTFail("expected insufficientSpace, got \(error)")
            }
        }

        _ = try await exportBackup(from: sourceRoot, container: container, to: packageURL)
        _ = try await makeOriginalLibrary(root: restoredRoot)
        let coordinator = makeRestoreCoordinator(root: restoredRoot, capacity: empty)
        await expectBackupErrorAsync {
            _ = try await coordinator.prepare(packageURL: packageURL)
        } verifying: { error in
            guard case .insufficientSpace = error as? BackupError else {
                return XCTFail("expected insufficientSpace, got \(error)")
            }
        }
    }

    // MARK: - Exclusion

    func testSensitiveDirectoriesNeverEnterBackup() async throws {
        let sourceRoot = try makeRoot("exclusion-source")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        try context.save()

        let sensitive: [(String, String)] = [
            ("cache/fake-token.txt", "token"),
            ("staging/private.tmp", "private"),
            ("external-generations/ChatGPT-TryOn-1/prompt.txt", "prompt"),
            ("backups/old.wardrobebackup/whatever", "old"),
            ("database/secret-notes.txt", "db"),
            ("logs/debug.log", "log"),
            ("migration/notes.txt", "migration notes"),
        ]
        for (relative, contents) in sensitive {
            let url = sourceRoot.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Exclusion.\(BackupFormat.packageExtension)")
        let summary = try await exportBackup(from: sourceRoot, container: container, to: packageURL)
        XCTAssertEqual(summary.unreferencedFileCount, 0)

        guard let enumerator = fm.enumerator(at: packageURL, includingPropertiesForKeys: [], options: []) else {
            return XCTFail("package unreadable")
        }
        var relativePaths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            relativePaths.append(String(
                BackupPathResolver.realPath(url.path)
                    .dropFirst(BackupPathResolver.realPath(packageURL.path).count + 1)
            ))
        }
        let joined = relativePaths.joined(separator: "\n")
        for forbidden in ["cache", "staging", "external-generations", "backups", "database", "logs", "migration", "secret", "token", "prompt.txt"] {
            XCTAssertFalse(joined.contains(forbidden), "package must not contain \(forbidden)")
        }
        XCTAssertTrue(relativePaths.contains("metadata/records.json"))
        XCTAssertTrue(relativePaths.contains(BackupPackageLayout.assetRelativePath(try StorageResourceID(rawValue: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))))
    }

    func testNonterminalGenerationBlocksBackup() async throws {
        let sourceRoot = try makeRoot("nonterminal-source")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        context.insert(GenerationRecord(id: Self.id(40), providerID: "mock", statusCode: GenerationStatus.running.rawValue, createdAt: Date(timeIntervalSince1970: 1)))
        try context.save()
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Nonterminal.\(BackupFormat.packageExtension)")

        await expectBackupErrorAsync {
            _ = try await self.exportBackup(from: sourceRoot, container: container, to: packageURL)
        } verifying: { error in
            XCTAssertEqual(error as? BackupError, .nonterminalGeneration)
        }
    }

    func testExistingBackupReplacedWithoutDataLoss() async throws {
        let sourceRoot = try makeRoot("replace-source")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        try context.save()
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Replace.\(BackupFormat.packageExtension)")

        let first = try await exportBackup(from: sourceRoot, container: container, to: packageURL)
        let second = try await exportBackup(from: sourceRoot, container: container, to: packageURL)
        XCTAssertNotEqual(first.backupID, second.backupID)
        _ = try BackupValidator().validate(packageURL: packageURL)
        let manifest = try BackupJSON.decoder().decode(BackupManifest.self, from: Data(contentsOf: packageURL.appendingPathComponent(BackupPackageLayout.manifestFileName)))
        XCTAssertEqual(manifest.backupID, second.backupID)
        let leftovers = try fm.contentsOfDirectory(atPath: backupDir.path).filter { $0.contains(".tmp") || $0.contains(".old-") }
        XCTAssertTrue(leftovers.isEmpty, "staging/old packages must be cleaned: \(leftovers)")
    }

    // MARK: - Restore Replacement & Rollback

    func testPendingRestoreBlocksSecondPrepareAndBackup() async throws {
        let root = try makeRoot("pending-single-root")
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Pending.\(BackupFormat.packageExtension)")
        do {
            let (storage, container) = try makeLibrary(root: root)
            try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
            let context = ModelContext(container)
            context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
            try context.save()
            _ = try await exportBackup(from: root, container: container, to: packageURL)
        }

        let coordinator = makeRestoreCoordinator(root: root)
        _ = try await coordinator.prepare(packageURL: packageURL)

        await expectBackupErrorAsync {
            _ = try await coordinator.prepare(packageURL: packageURL)
        } verifying: { error in
            XCTAssertEqual(error as? BackupError, .pendingRestoreExists)
        }

        let secondBackup = backupDir.appendingPathComponent("Second.\(BackupFormat.packageExtension)")
        do {
            let (_, container) = try makeLibrary(root: root)
            await expectBackupErrorAsync {
                _ = try await self.exportBackup(from: root, container: container, to: secondBackup)
            } verifying: { error in
                XCTAssertEqual(error as? BackupError, .pendingRestoreExists)
            }
        }

        _ = try applyRestore(to: root)
        let (restoredStorage, restoredContainer) = try makeLibrary(root: root)
        XCTAssertEqual(try SwiftDataBackupMetadataExporter(container: restoredContainer).exportRecords().clothingItems.count, 1)
        let restoredExists = try await restoredStorage.exists(try StorageResourceID(rawValue: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        XCTAssertTrue(restoredExists)
    }

    func testInterruptedRestoreResumesFromPreparedAndOriginalMoved() async throws {
        let sourceRoot = try makeRoot("interrupted-source")
        let (storage, container) = try makeLibrary(root: sourceRoot)
        try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        try context.save()
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("Interrupted.\(BackupFormat.packageExtension)")
        _ = try await exportBackup(from: sourceRoot, container: container, to: packageURL)

        // Scenario 1: crash after prepare (phase .prepared) -> resume applies.
        let restoredRoot = try makeRoot("interrupted-restored")
        _ = try await makeOriginalLibrary(root: restoredRoot, name: "Before")
        let coordinator = makeRestoreCoordinator(root: restoredRoot)
        _ = try await coordinator.prepare(packageURL: packageURL)
        let outcome = try applyRestore(to: restoredRoot)
        guard case .completed = outcome else { return XCTFail("prepared resume failed") }

        // Scenario 2: crash after the original moved but before candidate install.
        let restoredRoot2 = try makeRoot("interrupted-restored-2")
        _ = try await makeOriginalLibrary(root: restoredRoot2, name: "Before-2")
        let coordinator2 = makeRestoreCoordinator(root: restoredRoot2)
        _ = try await coordinator2.prepare(packageURL: packageURL)

        let workspace = try XCTUnwrap(try RestoreTransactionWorkspace.discoverPending(parent: restoredRoot2.deletingLastPathComponent()))
        var transaction = try XCTUnwrap(try RestoreTransactionWorkspace.readTransaction(in: workspace))
        try fm.moveItem(at: restoredRoot2, to: workspace.appendingPathComponent(RestoreTransactionWorkspace.rollbackDirectoryName))
        transaction.phase = .originalMoved
        try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)

        let outcome2 = try applyRestore(to: restoredRoot2)
        guard case .completed = outcome2 else { return XCTFail("originalMoved resume failed") }
        let (restoredStorage2, restoredContainer2) = try makeLibrary(root: restoredRoot2)
        XCTAssertEqual(try SwiftDataBackupMetadataExporter(container: restoredContainer2).exportRecords().clothingItems.count, 1)
        let restored2Exists = try await restoredStorage2.exists(try StorageResourceID(rawValue: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        XCTAssertTrue(restored2Exists)
    }

    func testFailedCandidateInstalledRollsBackAndOriginalLibraryReopens() async throws {
        let originalRoot = try makeRoot("rollback-original")
        let originalBytes: Data
        do {
            let (storage, container) = try makeLibrary(root: originalRoot)
            try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
            let context = ModelContext(container)
            context.insert(ClothingItem(id: Self.id(1), name: "Original", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
            try context.save()
            originalBytes = try await storage.read(try StorageResourceID(rawValue: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        }

        // Stage a transaction in phase .candidateInstalled with a broken candidate.
        let parent = originalRoot.deletingLastPathComponent()
        let operationID = UUID()
        let workspace = RestoreTransactionWorkspace.workspaceURL(operationID: operationID, parent: parent)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        try fm.moveItem(at: originalRoot, to: workspace.appendingPathComponent(RestoreTransactionWorkspace.rollbackDirectoryName))
        let candidateRoot = workspace.appendingPathComponent(RestoreTransactionWorkspace.candidateDirectoryName)
        try fm.createDirectory(at: candidateRoot, withIntermediateDirectories: false)
        try Data("garbage".utf8).write(to: candidateRoot.appendingPathComponent("library.json"))
        let transaction = RestoreTransaction(
            operationID: operationID,
            phase: .candidateInstalled,
            backupID: UUID(),
            sourceLibraryID: UUID(),
            sourceLibraryCreatedAt: Date(timeIntervalSince1970: 1),
            schemaVersion: BackupVersion.string(schemaVersion: WardrobeSchemaV1.versionIdentifier),
            storageLayoutVersion: StorageConfiguration.layoutVersion,
            recordCounts: .zero,
            assetCount: 0,
            totalAssetBytes: 0,
            createdAt: .now
        )
        try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)

        let outcome = try applyRestore(to: originalRoot)
        guard case let .rolledBack(result) = outcome else {
            return XCTFail("expected rollback, got \(outcome)")
        }
        XCTAssertTrue(result.rolledBack)

        // The original library must reopen with its records and assets intact.
        let (reopenedStorage, reopenedContainer) = try makeLibrary(root: originalRoot)
        let records = try SwiftDataBackupMetadataExporter(container: reopenedContainer).exportRecords()
        XCTAssertEqual(records.clothingItems.map(\.name), ["Original"])
        let reopenedBytes = try await reopenedStorage.read(try StorageResourceID(rawValue: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        XCTAssertEqual(reopenedBytes, originalBytes)
        XCTAssertFalse(fm.fileExists(atPath: workspace.path))
    }

    func testRollbackFailureBlocksStartup() throws {
        let originalRoot = try makeRoot("blocked-original")
        // Phase .originalMoved with neither the original at the root nor a
        // rollback snapshot: recovery is impossible and must block.
        try fm.removeItem(at: originalRoot)
        let parent = originalRoot.deletingLastPathComponent()
        let workspace = RestoreTransactionWorkspace.workspaceURL(operationID: UUID(), parent: parent)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        let transaction = RestoreTransaction(
            operationID: UUID(),
            phase: .originalMoved,
            backupID: UUID(),
            sourceLibraryID: UUID(),
            sourceLibraryCreatedAt: Date(timeIntervalSince1970: 1),
            schemaVersion: BackupVersion.string(schemaVersion: WardrobeSchemaV1.versionIdentifier),
            storageLayoutVersion: StorageConfiguration.layoutVersion,
            recordCounts: .zero,
            assetCount: 0,
            totalAssetBytes: 0,
            createdAt: .now
        )
        try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)

        XCTAssertThrowsError(try applyRestore(to: originalRoot)) {
            XCTAssertEqual($0 as? BackupError, .rollbackFailed)
        }
        XCTAssertFalse(fm.fileExists(atPath: originalRoot.path))
    }

    func testInternalBackupPackageSurvivesRestoreIntoNewRoot() async throws {
        // The library owns a backup inside its backups directory, then that
        // backup is restored into the same root. The package must survive the
        // replacement and must never be copied into itself.
        let root = try makeRoot("internal-single-root")
        do {
            let (storage, container) = try makeLibrary(root: root)
            try await storage.write(assetData("g1"), to: try StorageResourceID(owner: StorageOwner(kind: .garment, id: Self.id(1)), kind: .original(fileExtension: "jpg")))
            let context = ModelContext(container)
            context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
            try context.save()
            let internalPackage = root.appendingPathComponent("backups/Internal.\(BackupFormat.packageExtension)")
            _ = try await exportBackup(from: root, container: container, to: internalPackage)

            let coordinator = makeRestoreCoordinator(root: root)
            _ = try await coordinator.prepare(packageURL: internalPackage)
        }

        _ = try applyRestore(to: root)

        let preserved = root.appendingPathComponent("backups/Internal.\(BackupFormat.packageExtension)")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: preserved.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        _ = try BackupValidator().validate(packageURL: preserved)

        let (restoredStorage, restoredContainer) = try makeLibrary(root: root)
        XCTAssertEqual(try SwiftDataBackupMetadataExporter(container: restoredContainer).exportRecords().clothingItems.count, 1)
        let restoredExists = try await restoredStorage.exists(try StorageResourceID(rawValue: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        XCTAssertTrue(restoredExists)
    }

    func testBackupMissingReferencedFileFailsPreflight() async throws {
        let sourceRoot = try makeRoot("missing-source-file")
        let (_, container) = try makeLibrary(root: sourceRoot)
        let context = ModelContext(container)
        context.insert(ClothingItem(id: Self.id(1), name: "A", originalResourceID: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        try context.save()
        let backupDir = try makeRoot("backups")
        let packageURL = backupDir.appendingPathComponent("MissingSource.\(BackupFormat.packageExtension)")

        await expectBackupErrorAsync {
            _ = try await self.exportBackup(from: sourceRoot, container: container, to: packageURL)
        } verifying: { error in
            XCTAssertEqual(error as? BackupError, .missingAsset(resource: Self.resource(.garment, 1, .original(fileExtension: "jpg"))))
        }
        XCTAssertFalse(fm.fileExists(atPath: packageURL.path))
    }
}

// MARK: - Test Helpers

private extension BackupRecordsV1 {
    func counts() -> BackupRecordCounts {
        BackupRecordCounts(records: self)
    }

    func allResourceStrings() -> Set<String> {
        var result = Set<String>()
        for item in clothingItems {
            result.insert(item.originalResourceID)
            if let value = item.processedResourceID { result.insert(value) }
            if let value = item.thumbnailResourceID { result.insert(value) }
        }
        for image in personImages {
            result.insert(image.originalResourceID)
            if let value = image.processedResourceID { result.insert(value) }
            if let value = image.thumbnailResourceID { result.insert(value) }
        }
        for outfit in outfits { if let value = outfit.coverResourceID { result.insert(value) } }
        for item in outfitItems { if let value = item.thumbnailResourceIDSnapshot { result.insert(value) } }
        for generation in generations {
            if let value = generation.resultResourceID { result.insert(value) }
            if let value = generation.resultThumbnailResourceID { result.insert(value) }
        }
        for input in generationPersonInputs { result.insert(input.resourceIDSnapshot) }
        for input in generationGarmentInputs { result.insert(input.resourceIDSnapshot) }
        return result
    }
}

private extension XCTestCase {
    @MainActor
    func expectBackupErrorAsync(
        _ expression: () async throws -> Void,
        verifying: (Error) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            verifying(error)
        }
    }
}
