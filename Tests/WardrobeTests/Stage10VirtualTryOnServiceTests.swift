import XCTest
@testable import Wardrobe

@MainActor
final class Stage10VirtualTryOnServiceTests: XCTestCase {
    func testSuccessPersistsSnapshotsStateResultAndDiagnostics() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider())
        let output = try await fixture.service.generate(
            session: fixture.session,
            person: fixture.references,
            personName: fixture.profile.name,
            clothing: fixture.clothing
        )
        let record = try XCTUnwrap(fixture.repository.generationRecord(id: output.generationID))
        XCTAssertEqual(record.statusCode, GenerationStatus.succeeded.rawValue)
        XCTAssertEqual(record.providerID, "mock")
        XCTAssertEqual(record.providerModelID, "mock-v1")
        XCTAssertNotNil(record.providerRequestID)
        XCTAssertEqual(record.attemptCount, 1)
        XCTAssertEqual(record.personInputs.count, 1)
        XCTAssertEqual(record.garmentInputs.count, 1)
        XCTAssertEqual(record.garmentInputs.first?.slotCode, TryOnSlot.upperBody.rawValue)
        XCTAssertFalse(record.prompt.isEmpty)
        XCTAssertTrue(record.optionsJSON.contains("schemaVersion"))
        let resultExists = try await fixture.storage.exists(output.resultResourceID)
        let thumbnailExists = try await fixture.storage.exists(output.thumbnailResourceID)
        XCTAssertTrue(resultExists)
        XCTAssertTrue(thumbnailExists)
    }

    func testTransientFailureRetriesWithinSameRecord() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider(behavior: .transientFailures(count: 1)))
        let output = try await fixture.service.generate(session: fixture.session, person: fixture.references, personName: fixture.profile.name, clothing: fixture.clothing)
        let records = try fixture.repository.allGenerationRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, output.generationID)
        XCTAssertEqual(records.first?.attemptCount, 2)
        XCTAssertEqual(records.first?.statusCode, GenerationStatus.succeeded.rawValue)
    }

    func testProviderFailureKeepsFailedRecordWithoutResult() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider(behavior: .permanentFailure()))
        do {
            _ = try await fixture.service.generate(session: fixture.session, person: fixture.references, personName: fixture.profile.name, clothing: fixture.clothing)
            XCTFail("Expected provider failure")
        } catch VirtualTryOnServiceError.provider(.providerUnavailable) {}
        let record = try XCTUnwrap(fixture.repository.allGenerationRecords().first)
        XCTAssertEqual(record.statusCode, GenerationStatus.failed.rawValue)
        XCTAssertEqual(record.errorCode, "provider_unavailable")
        XCTAssertNil(record.resultResourceID)
        XCTAssertEqual(record.attemptCount, 1)
    }

    func testStorageFailureKeepsFailedRecord() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider(), storage: FailingGenerationStorage())
        do {
            _ = try await fixture.service.generate(session: fixture.session, person: fixture.references, personName: fixture.profile.name, clothing: fixture.clothing)
            XCTFail("Expected storage failure")
        } catch VirtualTryOnServiceError.resultStorageFailed {}
        let record = try XCTUnwrap(fixture.repository.allGenerationRecords().first)
        XCTAssertEqual(record.statusCode, GenerationStatus.failed.rawValue)
        XCTAssertEqual(record.errorCode, "result_storage_failed")
        XCTAssertNil(record.resultResourceID)
    }

    func testCancellationPersistsCancelledRecordAndNoResult() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider(behavior: .success(delay: .seconds(2))))
        let task = Task {
            try await fixture.service.generate(session: fixture.session, person: fixture.references, personName: fixture.profile.name, clothing: fixture.clothing)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try fixture.repository.allGenerationRecords().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try fixture.repository.allGenerationRecords().count, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch VirtualTryOnError.cancelled {}
        let record = try XCTUnwrap(fixture.repository.allGenerationRecords().first)
        XCTAssertEqual(record.statusCode, GenerationStatus.cancelled.rawValue)
        XCTAssertEqual(record.errorCode, "cancelled")
        XCTAssertNil(record.resultResourceID)
    }

    func testRegenerateCreatesLinkedRecordWithoutMutatingSource() async throws {
        let fixture = try makeFixture(provider: MockVirtualTryOnProvider())
        let first = try await fixture.service.generate(session: fixture.session, person: fixture.references, personName: fixture.profile.name, clothing: fixture.clothing)
        let sourceBefore = try XCTUnwrap(fixture.repository.generationRecord(id: first.generationID))
        let sourceResult = sourceBefore.resultResourceID
        let second = try await fixture.service.generate(session: fixture.session, person: fixture.references, personName: fixture.profile.name, clothing: fixture.clothing, sourceGenerationID: first.generationID)
        XCTAssertNotEqual(first.generationID, second.generationID)
        XCTAssertEqual(try fixture.repository.generationRecord(id: second.generationID)?.sourceGenerationID, first.generationID)
        XCTAssertEqual(try fixture.repository.generationRecord(id: first.generationID)?.resultResourceID, sourceResult)
        XCTAssertEqual(try fixture.repository.allGenerationRecords().count, 2)
    }

    func testRecoveryMarksEveryNonterminalRecordInterrupted() throws {
        let container = try WardrobeModelContainerFactory.inMemory()
        let repository = SwiftDataWardrobeRepository(container: container)
        let queued = GenerationRecord(providerID: "mock")
        let running = GenerationRecord(providerID: "mock", statusCode: GenerationStatus.running.rawValue)
        try repository.insert(queued); try repository.insert(running); try repository.save()
        XCTAssertEqual(try InterruptedGenerationRecoveryService(repository: repository).recover(), 2)
        for record in try repository.allGenerationRecords() {
            XCTAssertEqual(record.statusCode, GenerationStatus.failed.rawValue)
            XCTAssertEqual(record.errorCode, "interrupted")
            XCTAssertNotNil(record.completedAt)
        }
    }

    private func makeFixture(
        provider: any VirtualTryOnProvider,
        storage suppliedStorage: (any ExternalGenerationResultStorageServing)? = nil
    ) throws -> Fixture {
        let container = try WardrobeModelContainerFactory.inMemory()
        let repository = SwiftDataWardrobeRepository(container: container)
        let profile = PersonProfile(name: "Stage 10 人物", isDefault: true)
        let imageID = UUID()
        let imageOriginal = try resource(kind: .person, id: imageID, resource: .original(fileExtension: "png"))
        let imageProcessed = try resource(kind: .person, id: imageID, resource: .processed)
        let image = PersonImage(id: imageID, profile: profile, isPrimary: true, originalResourceID: imageOriginal.rawValue, processedResourceID: imageProcessed.rawValue, pixelWidth: 1, pixelHeight: 1)
        let clothingID = UUID()
        let garmentOriginal = try resource(kind: .garment, id: clothingID, resource: .original(fileExtension: "png"))
        let garmentProcessed = try resource(kind: .garment, id: clothingID, resource: .processed)
        let garment = ClothingItem(id: clothingID, name: "Stage 10 上衣", categoryCode: ClothingCategory.tops.rawValue, originalResourceID: garmentOriginal.rawValue, processedResourceID: garmentProcessed.rawValue)
        try repository.insert(profile); try repository.insert(image); try repository.insert(garment); try repository.save()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WardrobeStage10Tests-\(UUID().uuidString)", isDirectory: true)
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
        let resultStorage: any ExternalGenerationResultStorageServing = suppliedStorage ?? storage
        let loader = Stage10ImageLoader()
        let service = VirtualTryOnService(repository: repository, storage: resultStorage, requestBuilder: VirtualTryOnRequestBuilder(loader: loader), provider: provider)
        var session = TryOnSession(personProfileID: profile.id, selectedPersonImageIDs: [image.id])
        session.add(clothingID: garment.id, to: .upperBody)
        let reference = PersonImageRecord(id: image.id, profileID: profile.id, isPrimary: true, originalResourceID: imageOriginal, processedResourceID: imageProcessed, thumbnailResourceID: nil, pixelWidth: 1, pixelHeight: 1, createdAt: image.createdAt, updatedAt: image.updatedAt)
        let clothing = ClothingRecord(id: garment.id, draft: ClothingDraft(name: garment.name, categoryCode: garment.categoryCode), originalResourceID: garmentOriginal, processedResourceID: garmentProcessed, thumbnailResourceID: nil, archivedAt: nil, createdAt: garment.createdAt, updatedAt: garment.updatedAt)
        return Fixture(repository: repository, storage: storage, service: service, profile: profile, references: PersonReferenceSet(profileID: profile.id, primaryImage: reference, additionalImages: []), clothing: [clothing], session: session)
    }

    private func resource(kind: StorageOwnerKind, id: UUID, resource: StorageResourceKind) throws -> StorageResourceID {
        try StorageResourceID(owner: StorageOwner(kind: kind, id: id), kind: resource)
    }
}

@MainActor
private struct Fixture {
    let repository: SwiftDataWardrobeRepository
    let storage: StorageService
    let service: VirtualTryOnService
    let profile: PersonProfile
    let references: PersonReferenceSet
    let clothing: [ClothingRecord]
    let session: TryOnSession
}

private actor Stage10ImageLoader: TryOnResourceLoading {
    func data(for _: StorageResourceID) async throws -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}

private actor FailingGenerationStorage: ExternalGenerationResultStorageServing {
    struct Failure: Error {}
    func saveExternalGenerationResult(_: Data, mediaType _: String, generationID _: UUID) async throws -> StoredGenerationResources { throw Failure() }
    func deleteExternalGenerationResult(generationID _: UUID) async throws {}
}
