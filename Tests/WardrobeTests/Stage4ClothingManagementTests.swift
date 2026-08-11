import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Wardrobe

@MainActor
final class Stage4ClothingManagementTests: XCTestCase {
    func testImportsJPEGWithMetadataAndAllResources() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(root: fixture.library)
        let draft = ClothingDraft(
            name: "  蓝色外套  ", categoryCode: ClothingCategory.outerwear.rawValue,
            brand: "  Local Brand ", colorCodes: ["blue", "blue"], seasonCodes: ["winter"],
            styleCodes: ["casual"], materials: ["cotton"], tags: ["daily", "Daily"],
            isFavorite: true, notes: "  warm  "
        )

        let record = try await system.importer.importClothing(from: fixture.url, draft: draft)

        XCTAssertEqual(record.draft.name, "蓝色外套")
        XCTAssertEqual(record.draft.brand, "Local Brand")
        XCTAssertEqual(record.draft.tags, ["daily"])
        XCTAssertTrue(record.draft.isFavorite)
        let originalExists = try await system.storage.exists(record.originalResourceID)
        let processedExists = try await system.storage.exists(try XCTUnwrap(record.processedResourceID))
        let thumbnailExists = try await system.storage.exists(try XCTUnwrap(record.thumbnailResourceID))
        XCTAssertTrue(originalExists); XCTAssertTrue(processedExists); XCTAssertTrue(thumbnailExists)
    }

    func testImportsPNG() async throws {
        let fixture = try makeFixture(type: .png)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(root: fixture.library)
        let record = try await system.importer.importClothing(from: fixture.url, draft: ClothingDraft(name: "PNG 衬衫", categoryCode: "tops"))
        XCTAssertEqual(record.originalResourceID.rawValue.split(separator: ".").last, "png")
        let processedExists = try await system.storage.exists(try XCTUnwrap(record.processedResourceID))
        XCTAssertTrue(processedExists)
    }

    func testImportsHEICWhenRuntimeEncoderIsAvailable() async throws {
        let fixture: ImageFixture
        do { fixture = try makeFixture(type: .heic) }
        catch { throw XCTSkip("This ImageIO runtime cannot encode the HEIC test fixture: \(error)") }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(root: fixture.library)
        let record = try await system.importer.importClothing(from: fixture.url, draft: ClothingDraft(name: "HEIC 鞋", categoryCode: "footwear"))
        XCTAssertEqual(record.originalResourceID.rawValue.split(separator: ".").last, "heic")
        let thumbnailExists = try await system.storage.exists(try XCTUnwrap(record.thumbnailResourceID))
        XCTAssertTrue(thumbnailExists)
    }

    func testPersistentContainerAndStorageCanBeRecreated() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var clothingID: UUID!
        var processedID: StorageResourceID!
        do {
            let storage = try StorageService(configuration: StorageConfiguration(rootURL: fixture.library))
            let container = try WardrobeModelContainerFactory.production(databaseDirectory: fixture.library.appendingPathComponent("database"))
            let repository = SwiftDataWardrobeRepository(container: container)
            let importer = ImportClothingService(repository: repository, storage: storage, imageProcessing: ImageProcessingService(storage: storage))
            let record = try await importer.importClothing(from: fixture.url, draft: ClothingDraft(name: "可重启夹克"))
            clothingID = record.id
            processedID = record.processedResourceID
        }
        let rebuiltStorage = try StorageService(configuration: StorageConfiguration(rootURL: fixture.library))
        let rebuiltContainer = try WardrobeModelContainerFactory.production(databaseDirectory: fixture.library.appendingPathComponent("database"))
        let rebuiltRepository = SwiftDataWardrobeRepository(container: rebuiltContainer)
        XCTAssertNotNil(try rebuiltRepository.clothingItem(id: clothingID))
        let rebuiltExists = try await rebuiltStorage.exists(processedID)
        XCTAssertTrue(rebuiltExists)
    }

    func testEditFavoriteArchiveAndRestoreDoNotChangeResourceIDs() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(root: fixture.library)
        let original = try await system.importer.importClothing(from: fixture.url, draft: ClothingDraft(name: "Original"))
        let management = ClothingManagementService(repository: system.repository)
        var draft = original.draft
        draft.name = "Edited"
        let edited = try management.update(id: original.id, draft: draft)
        XCTAssertEqual(edited.originalResourceID, original.originalResourceID)
        XCTAssertEqual(edited.processedResourceID, original.processedResourceID)
        XCTAssertTrue(try management.setFavorite(id: original.id, value: true).draft.isFavorite)
        XCTAssertTrue(try management.setArchived(id: original.id, value: true).isArchived)
        XCTAssertFalse(try management.setArchived(id: original.id, value: false).isArchived)
    }

    func testSearchCombinedFiltersAndStableSort() throws {
        let container = try WardrobeModelContainerFactory.inMemory()
        let repository = SwiftDataWardrobeRepository(container: container)
        let first = try testItem(name: "Blue Coat", category: "outerwear", brand: "North", tags: ["travel"], favorite: true, createdAt: Date(timeIntervalSince1970: 10))
        first.colorCodes = ["blue"]; first.materials = ["wool"]; first.seasonCodes = ["winter"]
        let second = try testItem(name: "White Shirt", category: "tops", brand: "Studio", tags: ["work"], favorite: false, createdAt: Date(timeIntervalSince1970: 20))
        try repository.insert(first); try repository.insert(second); try repository.save()

        var query = ClothingQuery(searchText: "wool", categoryCode: "outerwear", seasonCode: "winter", favoritesOnly: true)
        XCTAssertEqual(try repository.clothingItems(matching: query).map(\.id), [first.id])
        query = ClothingQuery(searchText: "work", sort: .name)
        XCTAssertEqual(try repository.clothingItems(matching: query).map(\.id), [second.id])
        query = ClothingQuery(sort: .newest)
        XCTAssertEqual(try repository.clothingItems(matching: query).map(\.id), [second.id, first.id])

        let unknown = try testItem(name: "Future category", category: "future_category")
        try repository.insert(unknown); try repository.save()
        query = ClothingQuery(categoryCode: "future_category")
        XCTAssertEqual(try repository.clothingItems(matching: query).first?.draft.categoryCode, "future_category")
    }

    func testStorageImportFailureLeavesNoMetadata() async throws {
        let container = try WardrobeModelContainerFactory.inMemory()
        let repository = SwiftDataWardrobeRepository(container: container)
        let service = ImportClothingService(repository: repository, storage: ThrowingImportStorage(), imageProcessing: FailingProcessor())
        do { _ = try await service.importClothing(from: URL(fileURLWithPath: "/tmp/missing.jpg"), draft: ClothingDraft(name: "Failure")); XCTFail("Expected failure") }
        catch { XCTAssertTrue(try repository.allClothingItems().isEmpty) }
    }

    func testProcessingFailureRollsBackPublishedOwnerDirectory() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: fixture.library))
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
        let service = ImportClothingService(repository: repository, storage: storage, imageProcessing: FailingProcessor())
        do { _ = try await service.importClothing(from: fixture.url, draft: ClothingDraft(name: "Failure")); XCTFail("Expected failure") }
        catch {
            XCTAssertTrue(try repository.allClothingItems().isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.library.appendingPathComponent("garments").path), [])
        }
    }

    func testRepositorySaveFailureRollsBackPublishedResourcesAndPreservesPrimaryError() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: fixture.library))
        let service = ImportClothingService(repository: FailingImportRepository(), storage: storage, imageProcessing: ImageProcessingService(storage: storage))
        do { _ = try await service.importClothing(from: fixture.url, draft: ClothingDraft(name: "Failure")); XCTFail("Expected failure") }
        catch let failure as ClothingServiceFailure {
            XCTAssertEqual(failure.primaryError as? TestFailure, .repository)
            XCTAssertTrue(failure.cleanupIssues.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.library.appendingPathComponent("garments").path), [])
        }
    }

    func testPermanentDeleteWithoutReferencesRemovesMetadataAndResources() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(root: fixture.library)
        let record = try await system.importer.importClothing(from: fixture.url, draft: ClothingDraft(name: "Delete"))
        let deletion = makeDeletion(repository: system.repository, storage: system.storage)
        let result = try await deletion.permanentlyDelete(clothingID: record.id)
        XCTAssertNil(try system.repository.clothingItem(id: record.id))
        let originalExists = try await system.storage.exists(record.originalResourceID)
        XCTAssertFalse(originalExists)
        XCTAssertTrue(result.retainedResources.isEmpty)
    }

    func testOutfitSnapshotKeepsReferencedThumbnailAfterMetadataDeletion() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(root: fixture.library)
        let record = try await system.importer.importClothing(from: fixture.url, draft: ClothingDraft(name: "Outfit source"))
        let item = try XCTUnwrap(system.repository.clothingItem(id: record.id))
        let outfit = Outfit(name: "Snapshot")
        let snapshot = OutfitItem(outfit: outfit, clothingItem: item, clothingItemID: item.id, clothingNameSnapshot: item.name, thumbnailResourceIDSnapshot: record.thumbnailResourceID?.rawValue, slotCode: TryOnSlot.upperBody.rawValue)
        outfit.items = [snapshot]
        try system.repository.insert(outfit); try system.repository.save()

        let result = try await makeDeletion(repository: system.repository, storage: system.storage).permanentlyDelete(clothingID: record.id)
        XCTAssertNil(try system.repository.clothingItem(id: record.id))
        XCTAssertNil(try system.repository.outfit(id: outfit.id)?.items.first?.clothingItem)
        XCTAssertEqual(try system.repository.outfit(id: outfit.id)?.items.first?.thumbnailResourceIDSnapshot, record.thumbnailResourceID?.rawValue)
        let thumbnailExists = try await system.storage.exists(try XCTUnwrap(record.thumbnailResourceID))
        XCTAssertTrue(thumbnailExists)
        XCTAssertEqual(result.retainedResources, [try XCTUnwrap(record.thumbnailResourceID)])
    }

    func testGenerationSnapshotKeepsReferencedProcessedImageAndUnrelatedResources() async throws {
        let fixture1 = try makeFixture(type: .jpeg)
        let fixture2 = try makeFixture(type: .png, root: fixture1.root)
        defer { try? FileManager.default.removeItem(at: fixture1.root) }
        let system = try makeSystem(root: fixture1.library)
        let target = try await system.importer.importClothing(from: fixture1.url, draft: ClothingDraft(name: "Target"))
        let unrelated = try await system.importer.importClothing(from: fixture2.url, draft: ClothingDraft(name: "Unrelated"))
        let item = try XCTUnwrap(system.repository.clothingItem(id: target.id))
        let generation = GenerationRecord(providerID: "mock")
        let snapshot = GenerationGarmentInput(generation: generation, clothingItem: item, clothingItemID: item.id, clothingNameSnapshot: item.name, slotCode: TryOnSlot.upperBody.rawValue, resourceIDSnapshot: try XCTUnwrap(target.processedResourceID).rawValue)
        generation.garmentInputs = [snapshot]
        try system.repository.insert(generation); try system.repository.save()

        let result = try await makeDeletion(repository: system.repository, storage: system.storage).permanentlyDelete(clothingID: target.id)
        XCTAssertNil(try system.repository.generationRecord(id: generation.id)?.garmentInputs.first?.clothingItem)
        let targetExists = try await system.storage.exists(try XCTUnwrap(target.processedResourceID))
        let unrelatedExists = try await system.storage.exists(unrelated.originalResourceID)
        XCTAssertTrue(targetExists); XCTAssertTrue(unrelatedExists)
        XCTAssertEqual(result.retainedResources, [try XCTUnwrap(target.processedResourceID)])
    }

    func testCleanupFailureDoesNotRestoreDeletedMetadataOrDamageOtherRecords() async throws {
        let container = try WardrobeModelContainerFactory.inMemory()
        let repository = SwiftDataWardrobeRepository(container: container)
        let target = try testItem(name: "Target")
        let other = try testItem(name: "Other")
        try repository.insert(target); try repository.insert(other); try repository.save()
        let deletion = ClothingDeletionService(repository: repository, inspector: ResourceReferenceInspector(repository: repository), storage: FailingDeletionStorage())
        let result = try await deletion.permanentlyDelete(clothingID: target.id)
        XCTAssertNil(try repository.clothingItem(id: target.id))
        XCTAssertNotNil(try repository.clothingItem(id: other.id))
        XCTAssertEqual(result.cleanupIssues.count, 1)
    }

    func testResourceInspectorCoversEveryPersistedReferenceField() throws {
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
        let garmentOwner = StorageOwner(kind: .garment, id: UUID())
        let garmentOriginal = try StorageResourceID(owner: garmentOwner, kind: .original(fileExtension: "jpg"))
        let garmentProcessed = try StorageResourceID(owner: garmentOwner, kind: .processed)
        let garmentThumbnail = try StorageResourceID(owner: garmentOwner, kind: .thumbnail)
        let clothing = ClothingItem(
            id: garmentOwner.id, name: "Referenced", originalResourceID: garmentOriginal.rawValue,
            processedResourceID: garmentProcessed.rawValue, thumbnailResourceID: garmentThumbnail.rawValue
        )
        try repository.insert(clothing)

        let personOwner = StorageOwner(kind: .person, id: UUID())
        let personOriginal = try StorageResourceID(owner: personOwner, kind: .original(fileExtension: "png"))
        let personProcessed = try StorageResourceID(owner: personOwner, kind: .processed)
        let personThumbnail = try StorageResourceID(owner: personOwner, kind: .thumbnail)
        let profile = PersonProfile(name: "Person")
        let personImage = PersonImage(
            id: personOwner.id, profile: profile, originalResourceID: personOriginal.rawValue,
            processedResourceID: personProcessed.rawValue, thumbnailResourceID: personThumbnail.rawValue
        )
        profile.images = [personImage]
        try repository.insert(profile); try repository.insert(personImage)

        let outfitOwner = StorageOwner(kind: .outfit, id: UUID())
        let outfitCover = try StorageResourceID(owner: outfitOwner, kind: .outfitCover)
        let outfit = Outfit(id: outfitOwner.id, name: "Outfit", coverResourceID: outfitCover.rawValue)
        let outfitItem = OutfitItem(
            outfit: outfit, clothingItem: clothing, clothingItemID: clothing.id,
            thumbnailResourceIDSnapshot: garmentThumbnail.rawValue, slotCode: TryOnSlot.upperBody.rawValue
        )
        outfit.items = [outfitItem]
        try repository.insert(outfit)

        let generationOwner = StorageOwner(kind: .generation, id: UUID())
        let generationResult = try StorageResourceID(owner: generationOwner, kind: .generationResult(fileExtension: "png"))
        let generationThumbnail = try StorageResourceID(owner: generationOwner, kind: .thumbnail)
        let generation = GenerationRecord(
            id: generationOwner.id, providerID: "mock", resultResourceID: generationResult.rawValue,
            resultThumbnailResourceID: generationThumbnail.rawValue
        )
        let personInput = GenerationPersonInput(
            generation: generation, personProfile: profile, personProfileID: profile.id,
            personImage: personImage, personImageID: personImage.id, resourceIDSnapshot: personProcessed.rawValue
        )
        let garmentInput = GenerationGarmentInput(
            generation: generation, clothingItem: clothing, clothingItemID: clothing.id,
            slotCode: TryOnSlot.upperBody.rawValue, resourceIDSnapshot: garmentProcessed.rawValue
        )
        generation.personInputs = [personInput]; generation.garmentInputs = [garmentInput]
        try repository.insert(generation); try repository.save()

        let expected: Set<StorageResourceID> = [
            garmentOriginal, garmentProcessed, garmentThumbnail,
            personOriginal, personProcessed, personThumbnail,
            outfitCover, generationResult, generationThumbnail,
        ]
        let actual = try ResourceReferenceInspector(repository: repository).referencedResources(in: expected)
        XCTAssertEqual(actual, expected)
    }

    private func makeSystem(root: URL) throws -> TestSystem {
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
        return TestSystem(storage: storage, repository: repository, importer: ImportClothingService(repository: repository, storage: storage, imageProcessing: ImageProcessingService(storage: storage)))
    }

    private func makeDeletion(repository: SwiftDataWardrobeRepository, storage: StorageService) -> ClothingDeletionService {
        ClothingDeletionService(repository: repository, inspector: ResourceReferenceInspector(repository: repository), storage: storage)
    }

    private func testItem(name: String, category: String = "other", brand: String? = nil, tags: [String] = [], favorite: Bool = false, createdAt: Date = .now) throws -> ClothingItem {
        let id = UUID()
        return ClothingItem(id: id, name: name, categoryCode: category, brand: brand, tags: tags, isFavorite: favorite, originalResourceID: try StorageResourceID(owner: StorageOwner(kind: .garment, id: id), kind: .original(fileExtension: "jpg")).rawValue, createdAt: createdAt)
    }

    private func makeFixture(type: UTType, root suppliedRoot: URL? = nil) throws -> ImageFixture {
        let root = suppliedRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("WardrobeStage4Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        let fileExtension = type.preferredFilenameExtension ?? "img"
        let url = root.appendingPathComponent("fixture-\(UUID().uuidString).\(fileExtension)")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        guard CGImageDestinationFinalize(destination) else { throw TestFailure.encoding }
        return ImageFixture(root: root, library: library, url: url)
    }
}

private struct TestSystem {
    let storage: StorageService
    let repository: SwiftDataWardrobeRepository
    let importer: ImportClothingService
}

private struct ImageFixture { let root: URL; let library: URL; let url: URL }
private enum TestFailure: Error, Equatable { case storage, processing, repository, encoding }

private actor ThrowingImportStorage: ClothingAssetImporting {
    func importImage(from sourceURL: URL, for owner: StorageOwner) async throws -> StoredImageResources { throw TestFailure.storage }
    func deleteResourceDirectory(for owner: StorageOwner) async throws {}
}

private struct FailingProcessor: ImageProcessingServing {
    func process(originalResourceID: StorageResourceID, preset: ImageProcessingPreset) async throws -> ImageProcessingResult { throw TestFailure.processing }
    func process(originalResourceID: StorageResourceID, options: ImageProcessingOptions) async throws -> ImageProcessingResult { throw TestFailure.processing }
}

@MainActor
private final class FailingImportRepository: ClothingImportPersisting {
    func insertAndSave(_ item: ClothingItem) throws { throw TestFailure.repository }
}

private actor FailingDeletionStorage: ClothingAssetDeleting {
    func deleteResourceDirectory(for owner: StorageOwner) async throws { throw TestFailure.storage }
}
