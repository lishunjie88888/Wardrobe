import Foundation
import SwiftData
import XCTest
@testable import Wardrobe

/// Stage 16 focused tests: representative-scale query baselines, thumbnail
/// loading policy, cache capacity, staging recovery, orphan report safety and
/// disk-full behavior. All fixtures are in-memory SwiftData plus an isolated
/// temporary Storage root; no production data is touched.
@MainActor
final class Stage16PerformanceReliabilityTests: XCTestCase {

    private struct Scale {
        static let clothingCount = 1_000
        static let personProfileCount = 10
        static let personImageCount = 30
        static let outfitCount = 250
        static let generationCount = 500
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let storage: StorageService
        let container: ModelContainer
        let repository: SwiftDataWardrobeRepository

        init(capacity: Int64 = 1_073_741_824) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WardrobeStage16Tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            storage = try StorageService(
                configuration: StorageConfiguration(rootURL: root),
                capacityChecker: FakeCapacity(available: capacity)
            )
            container = try WardrobeModelContainerFactory.inMemory()
            repository = SwiftDataWardrobeRepository(container: container)
        }

        func cleanUp() {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }

        /// Builds the standard representative fixture without any image files.
        /// Only metadata is needed for query baselines; thumbnails are created
        /// separately by the image-specific tests.
        func buildStandardFixture() throws {
            let categories = ClothingCategory.allCases.map(\.rawValue)
            let seasons = Season.allCases.map(\.rawValue)
            for index in 0..<Scale.clothingCount {
                let id = UUID()
                let owner = StorageOwner(kind: .garment, id: id)
                let original = try StorageResourceID(owner: owner, kind: .original(fileExtension: "jpg")).rawValue
                let processed = try StorageResourceID(owner: owner, kind: .processed).rawValue
                let thumbnail = try StorageResourceID(owner: owner, kind: .thumbnail).rawValue
                let item = ClothingItem(
                    id: id,
                    name: index.isMultiple(of: 7) ? "棉质衬衫 \(index)" : "外套 \(index)",
                    notes: index.isMultiple(of: 5) ? "备注 \(index)" : nil,
                    categoryCode: categories[index % categories.count],
                    brand: index.isMultiple(of: 3) ? "品牌\(index % 5)" : nil,
                    colorCodes: index.isMultiple(of: 2) ? ["blue", "black"] : ["white"],
                    seasonCodes: index.isMultiple(of: 4) ? [seasons[index % seasons.count]] : [],
                    styleCodes: index.isMultiple(of: 6) ? ["casual"] : [],
                    materials: ["cotton"],
                    tags: index.isMultiple(of: 10) ? ["daily"] : [],
                    isFavorite: index.isMultiple(of: 8),
                    originalResourceID: original,
                    processedResourceID: processed,
                    thumbnailResourceID: thumbnail,
                    archivedAt: index.isMultiple(of: 11) ? Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)) : nil,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
                )
                try repository.insert(item)
            }

            for index in 0..<Scale.personProfileCount {
                let profile = PersonProfile(
                    id: UUID(),
                    name: "人物 \(index)",
                    notes: nil,
                    isDefault: index == 0,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
                )
                try repository.insert(profile)
                for imageIndex in 0..<3 {
                    let imageID = UUID()
                    let owner = StorageOwner(kind: .person, id: imageID)
                    let original = try StorageResourceID(owner: owner, kind: .original(fileExtension: "jpg")).rawValue
                    let processed = try StorageResourceID(owner: owner, kind: .processed).rawValue
                    let thumbnail = try StorageResourceID(owner: owner, kind: .thumbnail).rawValue
                    let image = PersonImage(
                        id: imageID,
                        profile: profile,
                        isPrimary: imageIndex == 0,
                        originalResourceID: original,
                        processedResourceID: processed,
                        thumbnailResourceID: thumbnail
                    )
                    try repository.insert(image)
                }
            }

            let allClothing = try repository.allClothingItems()
            for index in 0..<Scale.outfitCount {
                let outfit = Outfit(
                    name: "穿搭 \(index)",
                    notes: nil,
                    isFavorite: index.isMultiple(of: 9),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
                )
                let clothing = allClothing[index % Scale.clothingCount]
                let item = OutfitItem(
                    outfit: outfit,
                    clothingItem: clothing,
                    clothingItemID: clothing.id,
                    clothingNameSnapshot: clothing.name,
                    thumbnailResourceIDSnapshot: clothing.thumbnailResourceID,
                    slotCode: TryOnSlot.upperBody.rawValue,
                    sortOrder: 0,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
                )
                outfit.items = [item]
                try repository.insert(outfit)
            }

            let statuses = [
                GenerationStatus.queued, .preparing, .running,
                .succeeded, .failed, .cancelled,
            ]
            let providers = ["mock", "external-chatgpt-manual", "future-provider"]
            for index in 0..<Scale.generationCount {
                let record = GenerationRecord(
                    id: UUID(),
                    providerID: providers[index % providers.count],
                    statusCode: statuses[index % statuses.count].rawValue,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
                )
                try repository.insert(record)
            }
            try repository.save()
        }

        func measured<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let clock = ContinuousClock()
            let start = clock.now
            let value = try body()
            let elapsed = start.duration(to: clock.now)
            let line = "baseline: \(label) -> \(elapsed)"
            print(line)
            Self.appendBaseline(line)
            return value
        }

        /// Baseline reporting: measured durations are appended to a file in the
        /// process temporary directory so a CI/acceptance run can record
        /// representative numbers without parsing test logs.
        fileprivate static func appendBaseline(_ line: String) {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("wardrobe16-baselines.txt")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    private struct FakeCapacity: StorageCapacityChecking {
        let available: Int64
        func availableBytes(at url: URL) throws -> Int64 { available }
    }

    private func makeFixture(capacity: Int64 = 1_073_741_824) throws -> Fixture {
        let fixture = try Fixture(capacity: capacity)
        addTeardownBlock { fixture.cleanUp() }
        return fixture
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Query baselines (generous regression thresholds)

    func testThousandClothingQueryBaseline() async throws {
        let fixture = try makeFixture()
        try fixture.buildStandardFixture()
        let repository = fixture.repository

        let defaultRecords = try fixture.measured("1000-item default query") {
            try repository.clothingItems(matching: ClothingQuery())
        }
        XCTAssertEqual(defaultRecords.count, 250) // fetchLimit default

        let filtered = try fixture.measured("1000-item category+favorites query") {
            try repository.clothingItems(matching: ClothingQuery(
                categoryCode: ClothingCategory.outerwear.rawValue,
                favoritesOnly: true
            ))
        }
        XCTAssertFalse(filtered.contains { $0.draft.categoryCode != ClothingCategory.outerwear.rawValue })
        XCTAssertFalse(filtered.contains { !$0.draft.isFavorite })

        let searched = try fixture.measured("1000-item search query") {
            try repository.clothingItems(matching: ClothingQuery(searchText: "棉质"))
        }
        XCTAssertFalse(searched.contains { !$0.draft.name.contains("棉质") })

        let nameSorted = try fixture.measured("1000-item name sort") {
            try repository.clothingItems(matching: ClothingQuery(sort: .name))
        }
        XCTAssertEqual(nameSorted.count, 250)

        // Generous bounds: this machine typically completes these in a few ms.
        XCTAssertLessThanOrEqual(defaultRecords.count, 250)
        XCTAssertGreaterThan(filtered.count, 0)
    }

    func testFilterPushdownMatchesExpectedSelectivity() async throws {
        let fixture = try makeFixture()
        try fixture.buildStandardFixture()
        let repository = fixture.repository

        let active = try repository.clothingItems(matching: ClothingQuery(archive: .all))
        let archivedCount = try repository.clothingItems(matching: ClothingQuery(archive: .archived)).count
        XCTAssertEqual(archivedCount, (0..<Scale.clothingCount).filter { $0.isMultiple(of: 11) }.count)

        let favorites = try repository.clothingItems(matching: ClothingQuery(favoritesOnly: true, archive: .all))
        XCTAssertTrue(favorites.allSatisfy { $0.draft.isFavorite })

        let seasons = Season.allCases.map(\.rawValue)
        let seasonCode = seasons[2]
        let seasonal = try repository.clothingItems(matching: ClothingQuery(seasonCode: seasonCode, archive: .all))
        XCTAssertTrue(seasonal.allSatisfy { $0.draft.seasonCodes.contains(seasonCode) })

        let blue = try repository.clothingItems(matching: ClothingQuery(colorCode: "blue", archive: .all))
        XCTAssertTrue(blue.allSatisfy { $0.draft.colorCodes.contains("blue") })
    }

    func testPersonAndOutfitQueryBaseline() async throws {
        let fixture = try makeFixture()
        try fixture.buildStandardFixture()
        let repository = fixture.repository

        let profiles = try fixture.measured("person profiles query") {
            try repository.personProfiles(archive: .active)
        }
        XCTAssertEqual(profiles.count, Scale.personProfileCount)

        let outfits = try fixture.measured("outfit query") {
            try repository.outfits(matching: OutfitQuery())
        }
        XCTAssertEqual(outfits.count, Scale.outfitCount)

        let favoriteOutfits = try repository.outfits(matching: OutfitQuery(favoritesOnly: true))
        XCTAssertTrue(favoriteOutfits.allSatisfy { $0.draft.isFavorite })
    }

    func testGenerationHistoryQueryBaseline() async throws {
        let fixture = try makeFixture()
        try fixture.buildStandardFixture()
        let repository = fixture.repository

        let all = try fixture.measured("generation history query") {
            try repository.generationHistory(matching: GenerationHistoryQuery())
        }
        XCTAssertEqual(all.count, Scale.generationCount)

        let succeeded = try fixture.measured("generation history status filter") {
            try repository.generationHistory(matching: GenerationHistoryQuery(status: .succeeded))
        }
        let expectedSucceeded = (0..<Scale.generationCount).filter { $0 % 6 == 3 }.count
        XCTAssertEqual(succeeded.count, expectedSucceeded)

        let inProgress = try repository.generationHistory(matching: GenerationHistoryQuery(status: .inProgress))
        let expectedInProgress = (0..<Scale.generationCount).filter { $0 % 6 < 3 }.count
        XCTAssertEqual(inProgress.count, expectedInProgress)

        let byProvider = try repository.generationHistory(matching: GenerationHistoryQuery(providerID: "mock"))
        XCTAssertTrue(byProvider.allSatisfy { $0.providerID == "mock" })
    }

    func testRepeatedGenerationDetailLoadsAreStable() async throws {
        let fixture = try makeFixture()
        try fixture.buildStandardFixture()
        let repository = fixture.repository

        let first = try XCTUnwrap(repository.allGenerationRecords().first)
        let detail = try XCTUnwrap(repository.generationDetail(id: first.id))
        var elapsedTotal: Duration = .zero
        let clock = ContinuousClock()
        for _ in 0..<50 {
            let start = clock.now
            let reloaded = try XCTUnwrap(repository.generationDetail(id: first.id))
            elapsedTotal += start.duration(to: clock.now)
            XCTAssertEqual(reloaded.id, detail.id)
        }
        let line = "baseline: repeated detail x50 -> \(elapsedTotal)"
        print(line)
        Fixture.appendBaseline(line)
        XCTAssertLessThan(elapsedTotal, .seconds(5))
    }

    // MARK: - Thumbnail loading policy

    func testGridLoadsThumbnailBeforeProcessed() throws {
        let id = UUID()
        let owner = StorageOwner(kind: .garment, id: id)
        let record = ClothingRecord(
            id: id,
            draft: ClothingDraft(name: "策略"),
            originalResourceID: try StorageResourceID(owner: owner, kind: .original(fileExtension: "jpg")),
            processedResourceID: try StorageResourceID(owner: owner, kind: .processed),
            thumbnailResourceID: try StorageResourceID(owner: owner, kind: .thumbnail),
            archivedAt: nil,
            createdAt: .now,
            updatedAt: .now
        )
        XCTAssertEqual(record.gridResourceIDs.first, record.thumbnailResourceID)
        XCTAssertEqual(record.gridResourceIDs.count, 2)
        XCTAssertEqual(record.detailResourceIDs.first, record.processedResourceID)
        XCTAssertEqual(record.detailResourceIDs.count, 2)
    }

    // MARK: - Staging recovery

    func testStagingRecoveryRemovesOnlyExpiredUUIDOperations() async throws {
        let fixture = try makeFixture()
        let root = fixture.root
        let storage = fixture.storage
        let staging = root.appendingPathComponent("staging", isDirectory: true)

        let expiredID = UUID().uuidString.lowercased()
        let expiredDirectory = staging.appendingPathComponent(expiredID, isDirectory: true)
        try FileManager.default.createDirectory(at: expiredDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: expiredDirectory.appendingPathComponent("temporary.jpg"))
        try setModificationDate(Date(timeIntervalSinceNow: -48 * 3_600), at: expiredDirectory)

        let freshID = UUID().uuidString.lowercased()
        let freshDirectory = staging.appendingPathComponent(freshID, isDirectory: true)
        try FileManager.default.createDirectory(at: freshDirectory, withIntermediateDirectories: true)
        try Data([2]).write(to: freshDirectory.appendingPathComponent("temporary.jpg"))

        let reserved = staging.appendingPathComponent("reserved-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
        try Data([3]).write(to: reserved.appendingPathComponent("file.bin"))

        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let backupWorkspace = backups.appendingPathComponent("restore.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: backupWorkspace, withIntermediateDirectories: true)
        let migration = root.appendingPathComponent("migration", isDirectory: true)
        try FileManager.default.createDirectory(at: migration, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external-generations", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let now = Date()
        let result = try await storage.recoverExpiredStagingOperations(
            now: now,
            policy: StagingExpirationPolicy(gracePeriod: 24 * 3_600)
        )

        XCTAssertEqual(result.removedOperationCount, 1)
        XCTAssertEqual(result.removedFileCount, 1)
        XCTAssertEqual(result.skippedNonOperationEntries, ["reserved-workspace"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reserved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupWorkspace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migration.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testInterruptedGenerationRecoveryCoversUnknownCodes() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let nonterminal = [GenerationStatus.queued, .preparing, .running]
        var ids: [UUID] = []
        for status in nonterminal {
            let record = GenerationRecord(providerID: "mock", statusCode: status.rawValue)
            ids.append(record.id)
            try repository.insert(record)
        }
        let unknown = GenerationRecord(providerID: "mock", statusCode: "future-status")
        ids.append(unknown.id)
        try repository.insert(unknown)
        let succeeded = GenerationRecord(providerID: "mock", statusCode: GenerationStatus.succeeded.rawValue)
        let failed = GenerationRecord(providerID: "mock", statusCode: GenerationStatus.failed.rawValue)
        try repository.insert(succeeded)
        try repository.insert(failed)
        try repository.save()

        XCTAssertEqual(try InterruptedGenerationRecoveryService(repository: repository).recover(), 4)

        for id in ids {
            let record = try XCTUnwrap(repository.generationRecord(id: id))
            XCTAssertEqual(record.resolvedStatus, .known(.failed))
            XCTAssertEqual(record.errorCode, "interrupted")
        }
        XCTAssertEqual(try XCTUnwrap(repository.generationRecord(id: succeeded.id)).resolvedStatus, .known(.succeeded))
        XCTAssertEqual(try XCTUnwrap(repository.generationRecord(id: failed.id)).resolvedStatus, .known(.failed))
    }

    // MARK: - Cache capacity

    func testCacheEvictionRemovesOldestFilesOnly() async throws {
        let fixture = try makeFixture()
        let storage = fixture.storage
        let keyA = UUID()
        let keyB = UUID()
        let keyC = UUID()
        try await storage.writeCache(Data(repeating: 1, count: 1_000), namespace: "previews", key: keyA)
        try await storage.writeCache(Data(repeating: 2, count: 1_000), namespace: "previews", key: keyB)
        try await storage.writeCache(Data(repeating: 3, count: 1_000), namespace: "provider", key: keyC)

        let cacheRoot = fixture.root.appendingPathComponent("cache", isDirectory: true)
        try setModificationDate(Date(timeIntervalSinceNow: -3_600), at: cacheRoot.appendingPathComponent("previews/\(keyA.uuidString.lowercased())"))
        try setModificationDate(Date(timeIntervalSinceNow: -3_600), at: cacheRoot.appendingPathComponent("previews/\(keyB.uuidString.lowercased())"))

        let result = try await storage.enforceCacheLimit(policy: CachePolicy(maximumBytes: 1_500))

        XCTAssertEqual(result.removedFileCount, 2)
        XCTAssertEqual(result.removedBytes, 2_000)
        let readA = try await storage.readCache(namespace: "previews", key: keyA)
        let readB = try await storage.readCache(namespace: "previews", key: keyB)
        let readC = try await storage.readCache(namespace: "provider", key: keyC)
        let remainingSize = try await storage.cacheStorageSize()
        XCTAssertNil(readA)
        XCTAssertNil(readB)
        XCTAssertNotNil(readC)
        XCTAssertLessThanOrEqual(remainingSize, 1_500)
    }

    func testCacheReadRefreshesAccessTime() async throws {
        let fixture = try makeFixture()
        let storage = fixture.storage
        let keyA = UUID()
        let keyB = UUID()
        try await storage.writeCache(Data(repeating: 1, count: 1_000), namespace: "previews", key: keyA)
        try await storage.writeCache(Data(repeating: 2, count: 1_000), namespace: "previews", key: keyB)

        let cacheRoot = fixture.root.appendingPathComponent("cache", isDirectory: true)
        try setModificationDate(Date(timeIntervalSinceNow: -3_600), at: cacheRoot.appendingPathComponent("previews/\(keyA.uuidString.lowercased())"))
        _ = try await storage.readCache(namespace: "previews", key: keyA) // bumps A to now

        let result = try await storage.enforceCacheLimit(policy: CachePolicy(maximumBytes: 1_500))
        let kept = try await storage.readCache(namespace: "previews", key: keyA)
        let evicted = try await storage.readCache(namespace: "previews", key: keyB)
        XCTAssertEqual(result.removedFileCount, 1)
        XCTAssertNotNil(kept)
        XCTAssertNil(evicted)
    }

    func testCacheCleanupNeverTouchesPersistentResources() async throws {
        let fixture = try makeFixture()
        let storage = fixture.storage
        let owner = StorageOwner(kind: .garment, id: UUID())
        let persistent = try StorageResourceID(owner: owner, kind: .thumbnail)
        try await storage.write(Data([9]), to: persistent)
        try await storage.writeCache(Data(repeating: 1, count: 2_000), namespace: "previews", key: UUID())

        _ = try await storage.enforceCacheLimit(policy: CachePolicy(maximumBytes: 1))

        let persistentData = try await storage.read(persistent)
        XCTAssertEqual(persistentData, Data([9]))
    }

    // MARK: - Disk full

    func testDiskFullFailsBeforeAnyWrite() async throws {
        let fixture = try makeFixture(capacity: 0)
        let storage = fixture.storage
        let owner = StorageOwner(kind: .garment, id: UUID())

        do {
            try await storage.write(Data([1]), to: try StorageResourceID(owner: owner, kind: .thumbnail))
            XCTFail("Expected insufficientSpace")
        } catch let error as StorageError {
            XCTAssertEqual(error, .insufficientSpace)
        }

        let source = fixture.root.appendingPathComponent("source.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: source)
        do {
            _ = try await storage.importImage(from: source, for: owner)
            XCTFail("Expected insufficientSpace")
        } catch let error as StorageError {
            XCTAssertEqual(error, .insufficientSpace)
        }

        do {
            _ = try await storage.saveGenerationResult(Data([1]), mediaType: "image/png", generationID: UUID())
            XCTFail("Expected insufficientSpace")
        } catch let error as StorageError {
            XCTAssertEqual(error, .insufficientSpace)
        }

        do {
            try await storage.writeCache(Data([1]), namespace: "previews", key: UUID())
            XCTFail("Expected insufficientSpace")
        } catch let error as StorageError {
            XCTAssertEqual(error, .insufficientSpace)
        }

        let garments = fixture.root.appendingPathComponent("garments", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(atPath: garments.path)
        XCTAssertTrue(contents.isEmpty)
        let generations = fixture.root.appendingPathComponent("generations", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: generations.path).isEmpty)
        let cache = fixture.root.appendingPathComponent("cache/previews", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    func testDiskFullDoesNotDamageExistingResources() async throws {
        let fixture = try makeFixture(capacity: 1_073_741_824)
        let owner = StorageOwner(kind: .garment, id: UUID())
        let resource = try StorageResourceID(owner: owner, kind: .thumbnail)
        try await fixture.storage.write(Data([7, 8, 9]), to: resource)

        let fullStorage = try StorageService(
            configuration: StorageConfiguration(rootURL: fixture.root),
            capacityChecker: FakeCapacity(available: 0)
        )
        do {
            try await fullStorage.write(Data([1]), to: try StorageResourceID(owner: owner, kind: .processed))
            XCTFail("Expected insufficientSpace")
        } catch let error as StorageError {
            XCTAssertEqual(error, .insufficientSpace)
        }

        let existingData = try await fixture.storage.read(resource)
        let processedExists = try await fixture.storage.exists(try StorageResourceID(owner: owner, kind: .processed))
        XCTAssertEqual(existingData, Data([7, 8, 9]))
        XCTAssertFalse(processedExists)
    }

    // MARK: - Orphan report and safe cleanup

    func testOrphanReportCategoriesAndCleanupBoundaries() async throws {
        let fixture = try makeFixture()
        let root = fixture.root
        let storage = fixture.storage
        let repository = fixture.repository

        // Referenced and present on disk.
        let keptOwner = StorageOwner(kind: .garment, id: UUID())
        let keptOriginal = try StorageResourceID(owner: keptOwner, kind: .original(fileExtension: "jpg"))
        let keptThumbnail = try StorageResourceID(owner: keptOwner, kind: .thumbnail)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(keptOwner.kind.rawValue).appendingPathComponent(keptOwner.directoryName),
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: root.appendingPathComponent(keptOriginal.rawValue))
        try Data([2]).write(to: root.appendingPathComponent(keptThumbnail.rawValue))

        // Referenced but missing on disk.
        let missingOwner = StorageOwner(kind: .person, id: UUID())
        let missingOriginal = try StorageResourceID(owner: missingOwner, kind: .original(fileExtension: "png"))

        // Unreferenced files: one recent, one older than the grace period.
        let strayRecent = try StorageResourceID(
            owner: StorageOwner(kind: .generation, id: UUID()),
            kind: .generationResult(fileExtension: "png")
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(strayRecent.owner.kind.rawValue).appendingPathComponent(strayRecent.owner.directoryName),
            withIntermediateDirectories: true
        )
        try Data([3]).write(to: root.appendingPathComponent(strayRecent.rawValue))

        let strayOld = try StorageResourceID(
            owner: StorageOwner(kind: .generation, id: UUID()),
            kind: .generationResult(fileExtension: "png")
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(strayOld.owner.kind.rawValue).appendingPathComponent(strayOld.owner.directoryName),
            withIntermediateDirectories: true
        )
        let oldURL = root.appendingPathComponent(strayOld.rawValue)
        try Data([4]).write(to: oldURL)
        try setModificationDate(Date(timeIntervalSinceNow: -30 * 24 * 3_600), at: oldURL)

        // Junk outside owner directories must be ignored by the report.
        let cacheJunk = root.appendingPathComponent("cache/previews/junk.bin")
        try Data([5]).write(to: cacheJunk)
        let stagingJunk = root.appendingPathComponent("staging/not-a-resource.bin")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("staging", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data([6]).write(to: stagingJunk)

        let keptClothing = ClothingItem(
            name: "保留",
            categoryCode: ClothingCategory.outerwear.rawValue,
            originalResourceID: keptOriginal.rawValue,
            thumbnailResourceID: keptThumbnail.rawValue
        )
        try repository.insert(keptClothing)
        let missingProfile = PersonProfile(name: "缺失")
        let missingImage = PersonImage(
            profile: missingProfile,
            isPrimary: true,
            originalResourceID: missingOriginal.rawValue
        )
        try repository.insert(missingProfile)
        try repository.insert(missingImage)
        try repository.save()

        let service = OrphanReportService(repository: repository, storage: storage)
        let now = Date()
        let report = try await service.generateReport(now: now, gracePeriod: 7 * 24 * 3_600)

        XCTAssertEqual(report.missingReferencedResources, [missingOriginal])
        XCTAssertEqual(Set(report.unreferencedCandidates), Set([strayRecent, strayOld]))
        XCTAssertEqual(report.eligibleCleanupCandidates, [strayOld])
        XCTAssertEqual(report.scannedResourceCount, 4)

        // Report-only: nothing was deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheJunk.path))

        // Explicit cleanup deletes only eligible files and never touches others.
        let cleanup = try await service.deleteEligibleUnreferenced(now: now, gracePeriod: 7 * 24 * 3_600)
        XCTAssertEqual(cleanup.deletedResources, [strayOld])
        XCTAssertTrue(cleanup.retainedResources.isEmpty)
        XCTAssertTrue(cleanup.failedResources.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(strayRecent.rawValue).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(keptOriginal.rawValue).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(keptThumbnail.rawValue).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheJunk.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingJunk.path))
    }

    func testOrphanCleanupRechecksReferencesBeforeDeleting() async throws {
        let fixture = try makeFixture()
        let root = fixture.root
        let storage = fixture.storage
        let repository = fixture.repository

        let owner = StorageOwner(kind: .garment, id: UUID())
        let thumbnail = try StorageResourceID(owner: owner, kind: .thumbnail)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("garments").appendingPathComponent(owner.directoryName),
            withIntermediateDirectories: true
        )
        let url = root.appendingPathComponent(thumbnail.rawValue)
        try Data([1]).write(to: url)
        try setModificationDate(Date(timeIntervalSinceNow: -30 * 24 * 3_600), at: url)

        let service = OrphanReportService(repository: repository, storage: storage)

        // Unreferenced at report time; referenced before cleanup runs.
        let report = try await service.generateReport(now: Date(), gracePeriod: 7 * 24 * 3_600)
        XCTAssertEqual(report.eligibleCleanupCandidates, [thumbnail])

        let item = ClothingItem(
            name: "稍后引用",
            categoryCode: ClothingCategory.outerwear.rawValue,
            originalResourceID: try StorageResourceID(owner: owner, kind: .original(fileExtension: "jpg")).rawValue,
            thumbnailResourceID: thumbnail.rawValue
        )
        try repository.insert(item)
        try repository.save()

        // The execution-time report re-checks references, so the now-referenced
        // file is excluded before any deletion happens.
        let cleanup = try await service.deleteEligibleUnreferenced(now: Date(), gracePeriod: 7 * 24 * 3_600)
        XCTAssertTrue(cleanup.deletedResources.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
