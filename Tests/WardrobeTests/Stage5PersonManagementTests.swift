import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Wardrobe

@MainActor
final class Stage5PersonManagementTests: XCTestCase {
    func testCreatesEditsAndArchivesProfileWithoutRequiringImage() throws {
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
        let service = PersonManagementService(repository: repository)
        let created = try service.create(draft: PersonDraft(name: "  李舜杰  ", notes: "  reference  "))
        XCTAssertEqual(created.draft, PersonDraft(name: "李舜杰", notes: "reference"))
        XCTAssertTrue(created.images.isEmpty)

        let edited = try service.update(id: created.id, draft: PersonDraft(name: "新名字", notes: nil))
        XCTAssertEqual(edited.draft.name, "新名字")
        XCTAssertTrue(try service.setArchived(id: created.id, value: true).isArchived)
        XCTAssertTrue(try service.profiles().isEmpty)
        XCTAssertFalse(try service.setArchived(id: created.id, value: false).isArchived)
    }

    func testDefaultSelectionIsUniqueAndArchivingDefaultClearsIt() throws {
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
        let service = PersonManagementService(repository: repository)
        let first = try service.create(draft: PersonDraft(name: "First"))
        let second = try service.create(draft: PersonDraft(name: "Second"))
        try service.setDefault(id: first.id)
        try service.setDefault(id: second.id)
        var profiles = try service.profiles(archive: .all)
        XCTAssertEqual(profiles.filter(\.isDefault).map(\.id), [second.id])
        _ = try service.setArchived(id: second.id, value: true)
        profiles = try service.profiles(archive: .all)
        XCTAssertTrue(profiles.allSatisfy { !$0.isDefault })
        XCTAssertNil(try service.defaultReferenceSet())
    }

    func testImportsJPEGUsingPersonPresetAndPersistsDimensions() async throws {
        let fixture = try makeFixture(type: .jpeg, width: 80, height: 120)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(fixture: fixture)
        let profile = try system.management.create(draft: PersonDraft(name: "Person"))
        let image = try await system.importer.importImage(from: fixture.url, profileID: profile.id)
        XCTAssertTrue(image.isPrimary)
        XCTAssertEqual(image.pixelWidth, 80)
        XCTAssertEqual(image.pixelHeight, 120)
        XCTAssertEqual(image.processedResourceID?.owner.kind, .person)
        let originalExists = try await system.storage.exists(image.originalResourceID)
        let processedExists = try await system.storage.exists(try XCTUnwrap(image.processedResourceID))
        let thumbnailExists = try await system.storage.exists(try XCTUnwrap(image.thumbnailResourceID))
        XCTAssertTrue(originalExists); XCTAssertTrue(processedExists); XCTAssertTrue(thumbnailExists)
    }

    func testImportsPNGAndMultipleImagesUseSeparateOwners() async throws {
        let firstFixture = try makeFixture(type: .png)
        let secondFixture = try makeFixture(type: .jpeg, root: firstFixture.root)
        defer { try? FileManager.default.removeItem(at: firstFixture.root) }
        let system = try makeSystem(fixture: firstFixture)
        let profile = try system.management.create(draft: PersonDraft(name: "Multiple"))
        let first = try await system.importer.importImage(from: firstFixture.url, profileID: profile.id)
        let second = try await system.importer.importImage(from: secondFixture.url, profileID: profile.id)
        XCTAssertNotEqual(first.originalResourceID.owner.id, second.originalResourceID.owner.id)
        let loaded = try XCTUnwrap(try system.management.profiles().first)
        XCTAssertEqual(loaded.images.count, 2)
        XCTAssertEqual(loaded.images.filter(\.isPrimary).count, 1)
        XCTAssertEqual(loaded.primaryImage?.id, first.id)
    }

    func testImportsHEICWhenRuntimeEncoderIsAvailable() async throws {
        let fixture: Fixture
        do { fixture = try makeFixture(type: .heic) }
        catch { throw XCTSkip("This ImageIO runtime cannot encode the HEIC test fixture: \(error)") }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(fixture: fixture)
        let profile = try system.management.create(draft: PersonDraft(name: "HEIC"))
        let image = try await system.importer.importImage(from: fixture.url, profileID: profile.id)
        XCTAssertEqual(image.originalResourceID.rawValue.split(separator: ".").last, "heic")
    }

    func testSwitchingPrimaryIsUniqueAndReferenceSetIsOrdered() async throws {
        let firstFixture = try makeFixture(type: .jpeg)
        let secondFixture = try makeFixture(type: .png, root: firstFixture.root)
        defer { try? FileManager.default.removeItem(at: firstFixture.root) }
        let system = try makeSystem(fixture: firstFixture)
        let profile = try system.management.create(draft: PersonDraft(name: "Reference"))
        try system.management.setDefault(id: profile.id)
        let first = try await system.importer.importImage(from: firstFixture.url, profileID: profile.id)
        let second = try await system.importer.importImage(from: secondFixture.url, profileID: profile.id)
        try system.management.setPrimary(imageID: second.id, profileID: profile.id)
        let loaded = try XCTUnwrap(try system.management.profiles().first)
        XCTAssertEqual(loaded.images.filter(\.isPrimary).count, 1)
        XCTAssertEqual(loaded.primaryImage?.id, second.id)
        let references = try XCTUnwrap(system.management.defaultReferenceSet())
        XCTAssertEqual(references.primaryImage?.id, second.id)
        XCTAssertEqual(references.additionalImages.map(\.id), [first.id])
    }

    func testDeletingPrimaryDeterministicallyPromotesOldestRemainingImage() async throws {
        let firstFixture = try makeFixture(type: .jpeg)
        let secondFixture = try makeFixture(type: .png, root: firstFixture.root)
        let thirdFixture = try makeFixture(type: .jpeg, root: firstFixture.root)
        defer { try? FileManager.default.removeItem(at: firstFixture.root) }
        let system = try makeSystem(fixture: firstFixture)
        let profile = try system.management.create(draft: PersonDraft(name: "Primary"))
        let first = try await system.importer.importImage(from: firstFixture.url, profileID: profile.id)
        let second = try await system.importer.importImage(from: secondFixture.url, profileID: profile.id)
        _ = try await system.importer.importImage(from: thirdFixture.url, profileID: profile.id)
        _ = try await system.imageDeletion.permanentlyDelete(imageID: first.id)
        let loaded = try XCTUnwrap(try system.management.profiles().first)
        XCTAssertEqual(loaded.primaryImage?.id, second.id)
        XCTAssertEqual(loaded.images.filter(\.isPrimary).count, 1)
    }

    func testStorageAndProcessingFailuresLeaveNoMetadataOrOwnerDirectory() async throws {
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
        let profile = try PersonManagementService(repository: repository).create(draft: PersonDraft(name: "Failure"))
        let storageFailure = ImportPersonImageService(repository: repository, storage: ThrowingPersonStorage(), imageProcessing: FailingPersonProcessor())
        do { _ = try await storageFailure.importImage(from: URL(fileURLWithPath: "/tmp/missing.jpg"), profileID: profile.id); XCTFail("Expected failure") } catch {}
        XCTAssertTrue(try XCTUnwrap(repository.personProfile(id: profile.id)).images.isEmpty)

        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: fixture.library))
        let processingFailure = ImportPersonImageService(repository: repository, storage: storage, imageProcessing: FailingPersonProcessor())
        do { _ = try await processingFailure.importImage(from: fixture.url, profileID: profile.id); XCTFail("Expected failure") } catch {}
        XCTAssertTrue(try XCTUnwrap(repository.personProfile(id: profile.id)).images.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.library.appendingPathComponent("persons").path), [])
    }

    func testRepositoryFailureRollsBackPublishedPersonResources() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: fixture.library))
        let profile = PersonProfile(name: "Failure")
        let service = ImportPersonImageService(repository: FailingPersonRepository(profile: profile), storage: storage, imageProcessing: ImageProcessingService(storage: storage))
        do { _ = try await service.importImage(from: fixture.url, profileID: profile.id); XCTFail("Expected failure") }
        catch let failure as PersonServiceFailure { XCTAssertEqual(failure.primaryError as? PersonTestFailure, .repository) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.library.appendingPathComponent("persons").path), [])
    }

    func testDeletingUnreferencedImageRemovesMetadataAndFiles() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(fixture: fixture)
        let profile = try system.management.create(draft: PersonDraft(name: "Delete"))
        let image = try await system.importer.importImage(from: fixture.url, profileID: profile.id)
        let result = try await system.imageDeletion.permanentlyDelete(imageID: image.id)
        XCTAssertNil(try system.repository.personImage(id: image.id))
        let originalExists = try await system.storage.exists(image.originalResourceID)
        XCTAssertFalse(originalExists)
        XCTAssertTrue(result.retainedResources.isEmpty)
    }

    func testGenerationSnapshotRetainsReferencedImageAfterImageDeletion() async throws {
        let fixture = try makeFixture(type: .jpeg)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let system = try makeSystem(fixture: fixture)
        let profileRecord = try system.management.create(draft: PersonDraft(name: "History"))
        let imageRecord = try await system.importer.importImage(from: fixture.url, profileID: profileRecord.id)
        let profile = try XCTUnwrap(system.repository.personProfile(id: profileRecord.id))
        let image = try XCTUnwrap(system.repository.personImage(id: imageRecord.id))
        let generation = GenerationRecord(providerID: "mock")
        let snapshot = GenerationPersonInput(
            generation: generation, personProfile: profile, personProfileID: profile.id,
            personNameSnapshot: profile.name, personImage: image, personImageID: image.id,
            resourceIDSnapshot: try XCTUnwrap(imageRecord.processedResourceID).rawValue
        )
        generation.personInputs = [snapshot]
        try system.repository.insert(generation); try system.repository.save()

        let result = try await system.imageDeletion.permanentlyDelete(imageID: image.id)
        let saved = try XCTUnwrap(system.repository.generationRecord(id: generation.id)?.personInputs.first)
        XCTAssertNil(saved.personImage)
        XCTAssertEqual(saved.personImageID, image.id)
        XCTAssertEqual(saved.resourceIDSnapshot, imageRecord.processedResourceID?.rawValue)
        let processedExists = try await system.storage.exists(try XCTUnwrap(imageRecord.processedResourceID))
        XCTAssertTrue(processedExists)
        XCTAssertEqual(result.retainedResources, [try XCTUnwrap(imageRecord.processedResourceID)])
    }

    func testDeletingProfileCascadesImagesAndPreservesGenerationSnapshotResource() async throws {
        let firstFixture = try makeFixture(type: .jpeg)
        let secondFixture = try makeFixture(type: .png, root: firstFixture.root)
        defer { try? FileManager.default.removeItem(at: firstFixture.root) }
        let system = try makeSystem(fixture: firstFixture)
        let record = try system.management.create(draft: PersonDraft(name: "Cascade"))
        let firstRecord = try await system.importer.importImage(from: firstFixture.url, profileID: record.id)
        let secondRecord = try await system.importer.importImage(from: secondFixture.url, profileID: record.id)
        let profile = try XCTUnwrap(system.repository.personProfile(id: record.id))
        let first = try XCTUnwrap(system.repository.personImage(id: firstRecord.id))
        let generation = GenerationRecord(providerID: "mock")
        generation.personInputs = [GenerationPersonInput(
            generation: generation, personProfile: profile, personProfileID: profile.id,
            personNameSnapshot: profile.name, personImage: first, personImageID: first.id,
            resourceIDSnapshot: try XCTUnwrap(firstRecord.processedResourceID).rawValue
        )]
        try system.repository.insert(generation); try system.repository.save()

        let result = try await system.profileDeletion.permanentlyDelete(profileID: profile.id)
        XCTAssertNil(try system.repository.personProfile(id: profile.id))
        XCTAssertNil(try system.repository.personImage(id: firstRecord.id))
        XCTAssertNil(try system.repository.personImage(id: secondRecord.id))
        let saved = try XCTUnwrap(system.repository.generationRecord(id: generation.id)?.personInputs.first)
        XCTAssertNil(saved.personProfile); XCTAssertNil(saved.personImage)
        XCTAssertEqual(saved.personProfileID, profile.id)
        let retainedExists = try await system.storage.exists(try XCTUnwrap(firstRecord.processedResourceID))
        let deletedExists = try await system.storage.exists(secondRecord.originalResourceID)
        XCTAssertTrue(retainedExists); XCTAssertFalse(deletedExists)
        XCTAssertEqual(result.retainedResources, [try XCTUnwrap(firstRecord.processedResourceID)])
    }

    func testCleanupFailureDoesNotRestoreDeletedPersonMetadata() async throws {
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
        let profile = PersonProfile(name: "Delete")
        let owner = StorageOwner(kind: .person, id: UUID())
        let image = PersonImage(id: owner.id, profile: profile, isPrimary: true, originalResourceID: try StorageResourceID(owner: owner, kind: .original(fileExtension: "jpg")).rawValue)
        profile.images = [image]
        try repository.insert(profile); try repository.insert(image); try repository.save()
        let deletion = PersonImageDeletionService(repository: repository, inspector: ResourceReferenceInspector(repository: repository), storage: FailingPersonDeletionStorage())
        let result = try await deletion.permanentlyDelete(imageID: image.id)
        XCTAssertNil(try repository.personImage(id: image.id))
        XCTAssertNotNil(try repository.personProfile(id: profile.id))
        XCTAssertEqual(result.cleanupIssues.count, 1)
    }

    func testPersistentProfileDefaultPrimaryAndResourcesSurviveRebuild() async throws {
        let fixture = try makeFixture(type: .jpeg)
        let secondFixture = try makeFixture(type: .png, root: fixture.root)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var profileID: UUID!
        var primaryID: UUID!
        var resourceIDs: [StorageResourceID] = []
        do {
            let storage = try StorageService(configuration: StorageConfiguration(rootURL: fixture.library))
            let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.production(databaseDirectory: fixture.library.appendingPathComponent("database")))
            let management = PersonManagementService(repository: repository)
            let importer = ImportPersonImageService(repository: repository, storage: storage, imageProcessing: ImageProcessingService(storage: storage))
            let profile = try management.create(draft: PersonDraft(name: "Persistent")); profileID = profile.id
            try management.setDefault(id: profile.id)
            let first = try await importer.importImage(from: fixture.url, profileID: profile.id)
            let second = try await importer.importImage(from: secondFixture.url, profileID: profile.id)
            try management.setPrimary(imageID: second.id, profileID: profile.id); primaryID = second.id
            resourceIDs = [first.originalResourceID, try XCTUnwrap(first.processedResourceID), try XCTUnwrap(first.thumbnailResourceID), second.originalResourceID, try XCTUnwrap(second.processedResourceID), try XCTUnwrap(second.thumbnailResourceID)]
        }
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: fixture.library))
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.production(databaseDirectory: fixture.library.appendingPathComponent("database")))
        let references = try XCTUnwrap(PersonManagementService(repository: repository).defaultReferenceSet())
        XCTAssertEqual(references.profileID, profileID)
        XCTAssertEqual(references.primaryImage?.id, primaryID)
        for id in resourceIDs {
            let exists = try await storage.exists(id)
            let data = try await storage.read(id)
            XCTAssertTrue(exists); XCTAssertFalse(data.isEmpty)
        }
    }

    private func makeSystem(fixture: Fixture) throws -> PersonTestSystem {
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: fixture.library))
        let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
        let inspector = ResourceReferenceInspector(repository: repository)
        return PersonTestSystem(
            storage: storage,
            repository: repository,
            management: PersonManagementService(repository: repository),
            importer: ImportPersonImageService(repository: repository, storage: storage, imageProcessing: ImageProcessingService(storage: storage)),
            imageDeletion: PersonImageDeletionService(repository: repository, inspector: inspector, storage: storage),
            profileDeletion: PersonProfileDeletionService(repository: repository, inspector: inspector, storage: storage)
        )
    }

    private func makeFixture(type: UTType, root suppliedRoot: URL? = nil, width: Int = 64, height: Int = 96) throws -> Fixture {
        let root = suppliedRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("WardrobeStage5Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        let url = root.appendingPathComponent("fixture-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        guard CGImageDestinationFinalize(destination) else { throw PersonTestFailure.encoding }
        return Fixture(root: root, library: library, url: url)
    }
}

private struct Fixture { let root: URL; let library: URL; let url: URL }
private struct PersonTestSystem {
    let storage: StorageService
    let repository: SwiftDataWardrobeRepository
    let management: PersonManagementService
    let importer: ImportPersonImageService
    let imageDeletion: PersonImageDeletionService
    let profileDeletion: PersonProfileDeletionService
}
private enum PersonTestFailure: Error, Equatable { case storage, processing, repository, encoding }

private actor ThrowingPersonStorage: PersonAssetImporting {
    func importImage(from sourceURL: URL, for owner: StorageOwner) async throws -> StoredImageResources { throw PersonTestFailure.storage }
    func deleteResourceDirectory(for owner: StorageOwner) async throws {}
}

private struct FailingPersonProcessor: ImageProcessingServing {
    func process(originalResourceID: StorageResourceID, preset: ImageProcessingPreset) async throws -> ImageProcessingResult { throw PersonTestFailure.processing }
    func process(originalResourceID: StorageResourceID, options: ImageProcessingOptions) async throws -> ImageProcessingResult { throw PersonTestFailure.processing }
}

@MainActor
private final class FailingPersonRepository: PersonImportPersisting {
    let profile: PersonProfile
    init(profile: PersonProfile) { self.profile = profile }
    func personProfile(id: UUID) throws -> PersonProfile? { id == profile.id ? profile : nil }
    func insertPersonImageAndSave(_ image: PersonImage, at date: Date) throws -> PersonImageRecord { throw PersonTestFailure.repository }
}

private actor FailingPersonDeletionStorage: PersonAssetDeleting {
    func deleteResourceDirectory(for owner: StorageOwner) async throws { throw PersonTestFailure.storage }
}
