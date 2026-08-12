import Foundation
import XCTest
@testable import Wardrobe

@MainActor
final class Stage12GenerationHistoryTests: XCTestCase {
    func testQuerySortFiltersAndUnknownCodes() throws {
        let fixture = try makeFixture()
        let sameDate = Date(timeIntervalSince1970: 100)
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        ]
        try fixture.repository.insert(GenerationRecord(id: ids[0], providerID: "future-provider", statusCode: "future-status", createdAt: sameDate))
        try fixture.repository.insert(GenerationRecord(id: ids[1], providerID: "mock", statusCode: GenerationStatus.failed.rawValue, createdAt: sameDate))
        try fixture.repository.insert(GenerationRecord(providerID: "mock", statusCode: GenerationStatus.succeeded.rawValue, createdAt: Date(timeIntervalSince1970: 200)))
        try fixture.repository.insert(GenerationRecord(providerID: "external-chatgpt-manual", statusCode: GenerationStatus.cancelled.rawValue, createdAt: Date(timeIntervalSince1970: 50)))
        try fixture.repository.save()

        let all = try fixture.repository.generationHistory(matching: .init())
        XCTAssertEqual(all.first?.createdAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(Array(all.filter { $0.createdAt == sameDate }.map(\.id)), [ids[1], ids[0]])
        XCTAssertEqual(try fixture.repository.generationHistory(matching: .init(status: .succeeded)).count, 1)
        XCTAssertEqual(try fixture.repository.generationHistory(matching: .init(status: .failed)).count, 1)
        XCTAssertEqual(try fixture.repository.generationHistory(matching: .init(status: .cancelled)).count, 1)
        let future = try fixture.repository.generationHistory(matching: .init(providerID: "future-provider"))
        XCTAssertEqual(future.first?.status, .unknown("future-status"))
    }

    func testSnapshotFirstMappingOrderingAndInvalidJSON() throws {
        let fixture = try makeFixture()
        let record = try fixture.record(status: .succeeded, options: "not-json authorization=abc token=xyz")
        record.errorMessage = "failed at /Users/test/private/file with Bearer abc123"
        let accessoryA = try fixture.garment(record: record, name: "帽子", category: .accessories, slot: .accessories, order: 1)
        let top = try fixture.garment(record: record, name: "生成时白衬衫", category: .tops, slot: .upperBody, order: 0)
        let accessoryB = try fixture.garment(record: record, name: "手表", category: .accessories, slot: .accessories, order: 0)
        record.garmentInputs = [accessoryA, top, accessoryB]
        record.personInputs = [try fixture.person(record: record, order: 1), try fixture.person(record: record, order: 0)]
        try fixture.repository.insert(record); try fixture.repository.save()

        let detail = try XCTUnwrap(fixture.repository.generationDetail(id: record.id))
        XCTAssertEqual(detail.persons.map(\.sortOrder), [0, 1])
        XCTAssertEqual(detail.garments.map(\.clothingNameSnapshot), ["生成时白衬衫", "手表", "帽子"])
        XCTAssertTrue(detail.optionsText.contains("authorization=***"))
        XCTAssertTrue(detail.optionsText.contains("token=***"))
        XCTAssertFalse(detail.safeErrorMessage?.contains("/Users/test") == true)
        XCTAssertTrue(detail.safeErrorMessage?.contains("Bearer ***") == true)
    }

    func testInterruptedAndDeletedSourcesRemainReadable() throws {
        let fixture = try makeFixture()
        let record = try fixture.record(status: .failed)
        record.errorCode = "interrupted"
        let person = try fixture.person(record: record)
        let garment = try fixture.garment(record: record, name: "历史名称", category: .tops, slot: .upperBody)
        record.personInputs = [person]; record.garmentInputs = [garment]
        try fixture.repository.insert(record); try fixture.repository.save()
        try fixture.repository.deletePersonProfileAndSave(id: fixture.profile.id)
        try fixture.repository.deleteClothingItem(id: fixture.clothing.id)

        let detail = try XCTUnwrap(fixture.repository.generationDetail(id: record.id))
        XCTAssertEqual(detail.status, .interrupted)
        XCTAssertEqual(detail.persons.first?.personNameSnapshot, "历史人物")
        XCTAssertFalse(detail.persons.first?.hasCurrentProfile == true)
        XCTAssertEqual(detail.garments.first?.clothingNameSnapshot, "历史名称")
        XCTAssertFalse(detail.garments.first?.hasCurrentClothing == true)
    }

    func testRegeneratePreflightRestoresOrderAndSourceID() async throws {
        let fixture = try makeFixture()
        let record = try fixture.record(status: .succeeded)
        record.personInputs = [try fixture.person(record: record)]
        record.garmentInputs = [
            try fixture.garment(record: record, name: "包", category: .accessories, slot: .accessories, order: 1),
            try fixture.garment(record: record, name: "帽", category: .accessories, slot: .accessories, order: 0),
        ]
        try fixture.repository.insert(record); try fixture.repository.save()
        await fixture.storage.setExisting(Set(record.personInputs.compactMap { try? StorageResourceID(rawValue: $0.resourceIDSnapshot) } + record.garmentInputs.compactMap { try? StorageResourceID(rawValue: $0.resourceIDSnapshot) }))
        let service = fixture.service()
        let preflight = try await service.regeneratePreflight(id: record.id)
        XCTAssertTrue(preflight.canRegenerate)
        XCTAssertEqual(preflight.request?.sourceGenerationID, record.id)
        XCTAssertEqual(preflight.request?.garments.map(\.sortOrder), [0, 1])
    }

    func testRegenerateBlocksMissingAndArchivedSources() async throws {
        let fixture = try makeFixture()
        let record = try fixture.record(status: .succeeded)
        record.personInputs = [try fixture.person(record: record)]
        record.garmentInputs = [try fixture.garment(record: record, name: "上衣", category: .tops, slot: .upperBody)]
        try fixture.repository.insert(record); try fixture.repository.save()
        _ = try fixture.repository.setClothingArchived(id: fixture.clothing.id, archived: true, at: .now)
        let preflight = try await fixture.service().regeneratePreflight(id: record.id)
        XCTAssertFalse(preflight.canRegenerate)
        XCTAssertTrue(preflight.unavailableInputs.contains { $0.reason == .archived })
        XCTAssertTrue(preflight.unavailableInputs.contains { $0.reason == .missingResource })
    }

    func testSucceededSaveAsOutfitKeepsSlotAndDoesNotMutateGeneration() async throws {
        let fixture = try makeFixture()
        let record = try fixture.record(status: .succeeded)
        record.personInputs = [try fixture.person(record: record)]
        record.garmentInputs = [try fixture.garment(record: record, name: "上衣", category: .tops, slot: .upperBody)]
        try fixture.repository.insert(record); try fixture.repository.save()
        await fixture.storage.setExisting(Set(record.garmentInputs.compactMap { try? StorageResourceID(rawValue: $0.resourceIDSnapshot) }))
        let before = record.updatedAt
        let outfit = try await fixture.service().saveAsOutfit(id: record.id, draft: OutfitDraft(name: "来自生成"))
        XCTAssertEqual(outfit.items.first?.slotCode, TryOnSlot.upperBody.rawValue)
        XCTAssertEqual(record.updatedAt, before)
        do { _ = try await fixture.service().saveAsOutfit(id: try fixture.record(status: .failed).id, draft: OutfitDraft()); XCTFail("Expected unavailable") }
        catch { }
    }

    func testDeleteIsDBFirstPreservesSourceAndCleansExclusiveResults() async throws {
        let fixture = try makeFixture()
        let record = try fixture.record(status: .succeeded, withResult: true)
        record.personInputs = [try fixture.person(record: record)]
        record.garmentInputs = [try fixture.garment(record: record, name: "上衣", category: .tops, slot: .upperBody)]
        try fixture.repository.insert(record); try fixture.repository.save()
        let results = Set([record.resultResourceID, record.resultThumbnailResourceID].compactMap { $0 }.compactMap { try? StorageResourceID(rawValue: $0) })
        await fixture.storage.setExisting(results)
        let result = try await fixture.service().permanentlyDelete(id: record.id)
        XCTAssertEqual(result.cleanupIssueCount, 0)
        XCTAssertNil(try fixture.repository.generationRecord(id: record.id))
        XCTAssertNotNil(try fixture.repository.clothingItem(id: fixture.clothing.id))
        XCTAssertNotNil(try fixture.repository.personProfile(id: fixture.profile.id))
        let deleted = await fixture.storage.deleted()
        XCTAssertEqual(deleted, results)
    }

    func testDeletePreservesSharedOwnershipMismatchAndCleanupFailureIsNonfatal() async throws {
        let fixture = try makeFixture()
        let record = try fixture.record(status: .succeeded, withResult: true)
        let mismatch = try StorageResourceID(owner: StorageOwner(kind: .generation, id: UUID()), kind: .thumbnail)
        record.resultThumbnailResourceID = mismatch.rawValue
        try fixture.repository.insert(record)
        let shared = Outfit(name: "共享", coverResourceID: record.resultResourceID)
        let sharedItem = OutfitItem(outfit: shared, clothingItem: fixture.clothing, clothingItemID: fixture.clothing.id, clothingNameSnapshot: fixture.clothing.name, slotCode: TryOnSlot.upperBody.rawValue)
        shared.items = [sharedItem]
        try fixture.repository.insert(shared); try fixture.repository.save()
        let exclusive = try XCTUnwrap(record.resultResourceID).flatMapResource()
        await fixture.storage.setExisting([exclusive, mismatch]); await fixture.storage.setFailDelete(true)
        let result = try await fixture.service().permanentlyDelete(id: record.id)
        XCTAssertEqual(result.cleanupIssueCount, 0)
        let deleted = await fixture.storage.deleted()
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertNil(try fixture.repository.generationRecord(id: record.id))
        XCTAssertNotNil(try fixture.repository.outfit(id: shared.id))
    }

    func testCleanupFailureDoesNotRestoreDeletedMetadata() async throws {
        let fixture = try makeFixture()
        let record = try fixture.record(status: .succeeded, withResult: true)
        try fixture.repository.insert(record); try fixture.repository.save()
        let resources = Set([record.resultResourceID, record.resultThumbnailResourceID].compactMap { $0 }.compactMap { try? StorageResourceID(rawValue: $0) })
        await fixture.storage.setExisting(resources)
        await fixture.storage.setFailDelete(true)
        let result = try await fixture.service().permanentlyDelete(id: record.id)
        XCTAssertEqual(result.cleanupIssueCount, 2)
        XCTAssertNil(try fixture.repository.generationRecord(id: record.id))
    }

    func testExternalManifestOptionalSourceIsBackwardCompatible() throws {
        let legacy = ExternalGenerationManifest(schemaVersion: 1, workflowVersion: ExternalGenerationManifest.workflowVersion, packageID: .init(), createdAt: .now, personProfileID: UUID(), attachments: [], prompt: "p", source: .chatGPTManual)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let oldJSON = try encoder.encode(legacy)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(ExternalGenerationManifest.self, from: oldJSON)
        XCTAssertNil(old.sourceGenerationID)
        let sourceID = UUID()
        let manifest = ExternalGenerationManifest(schemaVersion: 1, workflowVersion: ExternalGenerationManifest.workflowVersion, packageID: .init(), createdAt: .now, personProfileID: UUID(), sourceGenerationID: sourceID, attachments: [], prompt: "p", source: .chatGPTManual)
        XCTAssertEqual(manifest.sourceGenerationID, sourceID)
    }

    func testExternalImporterPersistsSourceGenerationID() async throws {
        let fixture = try makeFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WardrobeStage12External-\(UUID().uuidString)", isDirectory: true)
        let storage = try StorageService(configuration: .init(rootURL: root))
        let sourceID = UUID()
        let attachment = ExternalGenerationAttachment(id: fixture.image.id, fileName: "person.png", role: .personPrimary, resourceID: try StorageResourceID(rawValue: fixture.image.processedResourceID!), personImageID: fixture.image.id, clothingItemID: nil, slot: nil, sortOrder: 0, displayName: "人物")
        let garment = ExternalGenerationAttachment(id: fixture.clothing.id, fileName: "top.png", role: .garment, resourceID: try StorageResourceID(rawValue: fixture.clothing.processedResourceID!), personImageID: nil, clothingItemID: fixture.clothing.id, slot: .upperBody, sortOrder: 0, displayName: "上衣")
        let manifest = ExternalGenerationManifest(schemaVersion: 1, workflowVersion: ExternalGenerationManifest.workflowVersion, packageID: .init(), createdAt: .now, personProfileID: fixture.profile.id, sourceGenerationID: sourceID, attachments: [attachment, garment], prompt: "p", source: .chatGPTManual)
        let package = ExternalGenerationPackage(manifest: manifest, directoryURL: root)
        let source = root.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.pngData.write(to: source)
        let imported = try await ExternalGenerationResultImporter(repository: fixture.repository, storage: storage).importResult(from: source, package: package)
        XCTAssertEqual(try fixture.repository.generationRecord(id: imported.generationID)?.sourceGenerationID, sourceID)
    }

    private func makeFixture() throws -> HistoryFixture {
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
        let profile = PersonProfile(name: "当前人物")
        let imageID = UUID()
        let imageResource = try StorageResourceID(owner: .init(kind: .person, id: imageID), kind: .processed)
        let image = PersonImage(id: imageID, profile: profile, isPrimary: true, originalResourceID: imageResource.rawValue, processedResourceID: imageResource.rawValue)
        let clothingID = UUID()
        let clothingResource = try StorageResourceID(owner: .init(kind: .garment, id: clothingID), kind: .processed)
        let clothing = ClothingItem(id: clothingID, name: "当前衣物", categoryCode: ClothingCategory.tops.rawValue, originalResourceID: clothingResource.rawValue, processedResourceID: clothingResource.rawValue)
        try repository.insert(profile); try repository.insert(image); try repository.insert(clothing); try repository.save()
        return HistoryFixture(repository: repository, profile: profile, image: image, clothing: clothing, storage: HistoryMemoryStorage())
    }

    private static let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

@MainActor
private struct HistoryFixture {
    let repository: SwiftDataWardrobeRepository
    let profile: PersonProfile
    let image: PersonImage
    let clothing: ClothingItem
    let storage: HistoryMemoryStorage

    func service() -> GenerationHistoryService {
        GenerationHistoryService(repository: repository, references: ResourceReferenceInspector(repository: repository), storage: storage, outfitService: OutfitService(repository: repository))
    }

    func record(status: GenerationStatus, options: String = "{}", withResult: Bool = false) throws -> GenerationRecord {
        let id = UUID()
        return GenerationRecord(id: id, providerID: "mock", statusCode: status.rawValue, prompt: "历史 Prompt", optionsJSON: options, resultResourceID: withResult ? try StorageResourceID(owner: .init(kind: .generation, id: id), kind: .generationResult(fileExtension: "png")).rawValue : nil, resultThumbnailResourceID: withResult ? try StorageResourceID(owner: .init(kind: .generation, id: id), kind: .thumbnail).rawValue : nil, completedAt: status.isTerminal ? .now : nil)
    }

    func person(record: GenerationRecord, order: Int = 0) throws -> GenerationPersonInput {
        GenerationPersonInput(generation: record, personProfile: profile, personProfileID: profile.id, personNameSnapshot: "历史人物", personImage: image, personImageID: image.id, resourceIDSnapshot: image.processedResourceID!, sortOrder: order)
    }

    func garment(record: GenerationRecord, name: String, category: ClothingCategory, slot: TryOnSlot, order: Int = 0) throws -> GenerationGarmentInput {
        let current: ClothingItem
        if category == .tops {
            current = clothing
        } else {
            let id = UUID()
            let resource = try StorageResourceID(owner: .init(kind: .garment, id: id), kind: .processed)
            current = ClothingItem(id: id, name: name, categoryCode: category.rawValue, originalResourceID: resource.rawValue, processedResourceID: resource.rawValue)
            try repository.insert(current)
        }
        return GenerationGarmentInput(generation: record, clothingItem: current, clothingItemID: current.id, clothingNameSnapshot: name, categoryCodeSnapshot: category.rawValue, slotCode: slot.rawValue, resourceIDSnapshot: current.processedResourceID!, sortOrder: order)
    }
}

private actor HistoryMemoryStorage: GenerationHistoryImageLoading, GenerationHistoryStorageServing {
    private var existing = Set<StorageResourceID>()
    private var removed = Set<StorageResourceID>()
    private var failure = false
    func setExisting(_ values: Set<StorageResourceID>) { existing = values }
    func setFailDelete(_ value: Bool) { failure = value }
    func data(for _: StorageResourceID) throws -> Data { Data() }
    func exists(_ resourceID: StorageResourceID) -> Bool { existing.contains(resourceID) }
    func delete(_ resourceID: StorageResourceID) throws { if failure { throw CocoaError(.fileWriteUnknown) }; existing.remove(resourceID); removed.insert(resourceID) }
    func deleted() -> Set<StorageResourceID> { removed }
}

private extension String {
    func flatMapResource() throws -> StorageResourceID { try StorageResourceID(rawValue: self) }
}
