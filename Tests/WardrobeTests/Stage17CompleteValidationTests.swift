import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Wardrobe

@MainActor
final class Stage17CompleteValidationTests: XCTestCase {

    // MARK: - V1 core loop (§6)
    // Add Clothing → create Person → join Try-On → Mock generate → persisted
    // Generation → Save Outfit → close/reopen container → all data intact with
    // correct relationships. No real AI is involved.
    func testCoreLoopPersistsEveryEntityAndRelationshipAcrossContainerRecreation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeStage17CoreLoop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseDirectory = root.appendingPathComponent("database", isDirectory: true)

        var clothingID: UUID!
        var processedClothingID: StorageResourceID!
        var profileID: UUID!
        var personImageID: UUID!
        var personProcessedID: StorageResourceID?
        var generationID: UUID!
        var resultResourceID: StorageResourceID!
        var resultThumbnailID: StorageResourceID!
        var outfitID: UUID!

        do {
            let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
            let container = try WardrobeModelContainerFactory.production(databaseDirectory: databaseDirectory)
            let repository = SwiftDataWardrobeRepository(container: container)
            let imageProcessing = ImageProcessingService(storage: storage)

            // 1. Add Clothing through the real importer.
            let clothingURL = try Self.writeImageFixture(to: root, name: "core-clothing.jpg", type: .jpeg)
            let clothingRecord = try await ImportClothingService(
                repository: repository,
                storage: storage,
                imageProcessing: imageProcessing
            ).importClothing(
                from: clothingURL,
                draft: ClothingDraft(name: "核心闭环外套", categoryCode: ClothingCategory.outerwear.rawValue)
            )
            clothingID = clothingRecord.id
            processedClothingID = try XCTUnwrap(clothingRecord.processedResourceID)

            // 2. Create/select Person and import a full-body reference image.
            let profile = try PersonManagementService(repository: repository).create(draft: PersonDraft(name: "核心闭环人物"))
            profileID = profile.id
            let personURL = try Self.writeImageFixture(to: root, name: "core-person.jpg", type: .jpeg)
            let image = try await ImportPersonImageService(
                repository: repository,
                storage: storage,
                imageProcessing: imageProcessing
            ).importImage(from: personURL, profileID: profileID)
            personImageID = image.id
            personProcessedID = image.processedResourceID

            // 3. Join Try-On.
            var session = TryOnSession(personProfileID: profileID, selectedPersonImageIDs: [personImageID])
            session.add(clothingID: clothingID, to: .outerwear)

            // 4. Mock generate → persisted GenerationRecord + result files.
            let service = VirtualTryOnService(
                repository: repository,
                storage: storage,
                requestBuilder: VirtualTryOnRequestBuilder(loader: storage),
                provider: MockVirtualTryOnProvider()
            )
            let references = try XCTUnwrap(PersonManagementService(repository: repository).referenceSet(profileID: profileID))
            let output = try await service.generate(
                session: session,
                person: references,
                personName: profile.draft.name,
                clothing: [clothingRecord]
            )
            generationID = output.generationID
            resultResourceID = output.resultResourceID
            resultThumbnailID = output.thumbnailResourceID

            // 5. Save Outfit from the succeeded generation.
            let outfit = try await GenerationHistoryService(
                repository: repository,
                references: ResourceReferenceInspector(repository: repository),
                storage: storage,
                outfitService: OutfitService(repository: repository)
            ).saveAsOutfit(id: generationID, draft: OutfitDraft(name: "核心闭环穿搭"))
            outfitID = outfit.id

            // In-flight sanity before the container is closed.
            let record = try XCTUnwrap(repository.generationRecord(id: generationID))
            XCTAssertEqual(record.statusCode, GenerationStatus.succeeded.rawValue)
            XCTAssertEqual(record.personInputs.count, 1)
            XCTAssertEqual(record.garmentInputs.count, 1)
            XCTAssertEqual(record.garmentInputs.first?.slotCode, TryOnSlot.outerwear.rawValue)
            let resultExists = try await storage.exists(resultResourceID)
            XCTAssertTrue(resultExists)
            let clothingProcessedExists = try await storage.exists(processedClothingID)
            XCTAssertTrue(clothingProcessedExists)
            let personProcessedExists = try await storage.exists(try XCTUnwrap(personProcessedID))
            XCTAssertTrue(personProcessedExists)
            XCTAssertEqual(try repository.outfit(id: outfitID)?.items.count, 1)
        }

        // 6. Close and reopen the same root: data and relationships must survive.
        do {
            let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
            let container = try WardrobeModelContainerFactory.production(databaseDirectory: databaseDirectory)
            let repository = SwiftDataWardrobeRepository(container: container)

            let outfit = try XCTUnwrap(repository.outfit(id: outfitID))
            XCTAssertEqual(outfit.name, "核心闭环穿搭")
            XCTAssertEqual(outfit.items.first?.clothingItemID, clothingID)

            let clothing = try XCTUnwrap(repository.clothingItem(id: clothingID))
            XCTAssertEqual(clothing.name, "核心闭环外套")
            XCTAssertEqual(clothing.processedResourceID, processedClothingID.rawValue)

            let profile = try XCTUnwrap(repository.personProfile(id: profileID))
            XCTAssertEqual(profile.name, "核心闭环人物")
            XCTAssertEqual(profile.images.first?.id, personImageID)

            let record = try XCTUnwrap(repository.generationRecord(id: generationID))
            XCTAssertEqual(record.statusCode, GenerationStatus.succeeded.rawValue)
            XCTAssertEqual(record.garmentInputs.first?.clothingItemID, clothingID)
            XCTAssertEqual(record.personInputs.first?.personProfileID, profileID)
            XCTAssertEqual(record.resultResourceID, resultResourceID.rawValue)
            XCTAssertEqual(record.resultThumbnailResourceID, resultThumbnailID.rawValue)

            // Files survive the reopen too.
            let resultExists = try await storage.exists(resultResourceID)
            XCTAssertTrue(resultExists)
            let thumbnailExists = try await storage.exists(resultThumbnailID)
            XCTAssertTrue(thumbnailExists)
            let clothingProcessedExists = try await storage.exists(processedClothingID)
            XCTAssertTrue(clothingProcessedExists)
            let personProcessedExists = try await storage.exists(try XCTUnwrap(personProcessedID))
            XCTAssertTrue(personProcessedExists)

            XCTAssertTrue(try LibraryConsistencyValidator().validate(container: container).isEmpty)
        }
    }

    // MARK: - Fresh startup scenario (§12)
    // Empty root → bootstrap (Storage layout + production container + AppEnvironment)
    // → usable, consistency-valid V1 library.
    func testFreshRootBootstrapBuildsValidV1Library() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeStage17Fresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
        let container = try WardrobeModelContainerFactory.production(
            databaseDirectory: root.appendingPathComponent("database", isDirectory: true)
        )
        _ = try AppEnvironment(
            applicationName: "Wardrobe",
            modelContainer: container,
            storageService: storage,
            imageProcessingService: ImageProcessingService(storage: storage)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("database").path))

        let repository = SwiftDataWardrobeRepository(container: container)
        let id = UUID()
        let resource = try StorageResourceID(
            owner: StorageOwner(kind: .garment, id: id),
            kind: .original(fileExtension: "jpg")
        )
        try repository.insertAndSave(ClothingItem(
            id: id,
            name: "启动后写入",
            categoryCode: ClothingCategory.tops.rawValue,
            originalResourceID: resource.rawValue
        ))
        XCTAssertEqual(try repository.clothingItem(id: id)?.name, "启动后写入")
        XCTAssertTrue(try LibraryConsistencyValidator().validate(container: container).isEmpty)
    }

    // MARK: - Fixture helpers

    private static func writeImageFixture(to root: URL, name: String, type: UTType) throws -> URL {
        let url = root.appendingPathComponent("fixture-\(UUID().uuidString)-\(name)")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Stage17FixtureError.encoding
        }
        return url
    }
}

private enum Stage17FixtureError: Error {
    case encoding
}
