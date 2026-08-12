import Foundation
import SwiftData
import XCTest
@testable import Wardrobe

private enum MigrationTestSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Item.self] }

    @Model final class Item {
        @Attribute(.unique) var id: UUID
        var name: String
        init(id: UUID, name: String) { self.id = id; self.name = name }
    }
}

private enum MigrationTestSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Item.self] }

    @Model final class Item {
        @Attribute(.unique) var id: UUID
        var name: String
        var notes: String?
        init(id: UUID, name: String, notes: String? = nil) {
            self.id = id; self.name = name; self.notes = notes
        }
    }
}

private enum MigrationTestSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [Item.self] }

    @Model final class Item {
        @Attribute(.unique) var id: UUID
        var name: String
        var notes: String?
        var normalizedName: String = ""
        init(id: UUID, name: String, notes: String? = nil, normalizedName: String = "") {
            self.id = id; self.name = name; self.notes = notes; self.normalizedName = normalizedName
        }
    }
}

private enum MigrationTestLightweightPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MigrationTestSchemaV1.self, MigrationTestSchemaV2.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: MigrationTestSchemaV1.self, toVersion: MigrationTestSchemaV2.self)]
    }
}

private enum MigrationTestCustomPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MigrationTestSchemaV2.self, MigrationTestSchemaV3.self]
    }
    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: MigrationTestSchemaV2.self,
                toVersion: MigrationTestSchemaV3.self,
                willMigrate: nil,
                didMigrate: { context in
                    for item in try context.fetch(FetchDescriptor<MigrationTestSchemaV3.Item>()) {
                        item.normalizedName = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                    try context.save()
                }
            )
        ]
    }
}

private actor InjectedStorageMigrationStep: StorageMigrationStep {
    enum Failure: Error { case injected }
    private(set) var transformed = false
    private(set) var rolledBack = false
    let failValidation: Bool

    init(failValidation: Bool) { self.failValidation = failValidation }
    func transform() { transformed = true }
    func validate() throws { if failValidation { throw Failure.injected } }
    func commit() {}
    func rollback() { transformed = false; rolledBack = true }
    func state() -> (Bool, Bool) { (transformed, rolledBack) }
}

@MainActor
final class Stage13SchemaMigrationTests: XCTestCase {
    private let fm = FileManager.default

    func testPublishedSchemaFreezeContractAndVersionSources() throws {
        XCTAssertEqual(WardrobeSchemaV1.versionIdentifier, Schema.Version(1, 0, 0), "Published schema must not be edited. Create WardrobeSchemaV2 instead.")
        XCTAssertEqual(WardrobeSchemaV1.models.count, 8, "Published schema must not be edited. Create WardrobeSchemaV2 instead.")
        XCTAssertEqual(WardrobeMigrationPlan.schemas.count, 1)
        XCTAssertTrue(WardrobeMigrationPlan.schemas.first == WardrobeSchemaV1.self)
        XCTAssertTrue(WardrobeMigrationPlan.stages.isEmpty)
        XCTAssertEqual(WardrobeSchemaRegistry.current, WardrobeSchemaV1.versionIdentifier)
        XCTAssertEqual(WardrobeSchemaRegistry.supported, [WardrobeSchemaV1.versionIdentifier])
        XCTAssertEqual(LibraryVersionDescriptor.current.storageLayoutVersion, 1)

        let schema = Schema(versionedSchema: WardrobeSchemaV1.self)
        let contract = schema.entities.sorted { $0.name < $1.name }.map { entity in
            "\(entity.name):" + entity.properties.sorted { $0.name < $1.name }.map { property in
                if let relationship = property as? Schema.Relationship {
                    return "\(property.name)>\(relationship.destination)[\(relationship.deleteRule.rawValue)]"
                }
                return "\(property.name):\(String(describing: property.valueType))\(property.isOptional ? "?" : "!")"
            }.joined(separator: ",")
        }
        XCTAssertEqual(contract, Self.frozenV1Contract, "Published schema must not be edited. Create WardrobeSchemaV2 instead.")
    }

    func testPreflightBlocksFutureMismatchInvalidAndInterruptedLibraries() {
        let currentManifest = manifest(layout: 1)
        let preflight = MigrationPreflight()
        XCTAssertEqual(preflight.evaluate(manifest: currentManifest, schemaVersion: .init(1, 0, 0), checkpoint: nil), .current)
        XCTAssertEqual(preflight.evaluate(manifest: manifest(layout: 2), schemaVersion: .init(1, 0, 0), checkpoint: nil), .unsupportedStorageLayout(2))
        XCTAssertEqual(preflight.evaluate(manifest: currentManifest, schemaVersion: .init(2, 0, 0), checkpoint: nil), .unsupportedFutureSchema(.init(2, 0, 0)))
        XCTAssertEqual(preflight.evaluate(manifest: currentManifest, schemaVersion: .init(0, 9, 0), checkpoint: nil), .noMigrationPath(.init(0, 9, 0)))
        XCTAssertEqual(preflight.evaluate(manifest: nil, schemaVersion: nil, checkpoint: nil), .invalidManifest)
        let checkpoint = LibraryMigrationCheckpoint(source: .current, target: .current, phase: .transforming)
        XCTAssertEqual(preflight.evaluate(manifest: currentManifest, schemaVersion: .init(1, 0, 0), checkpoint: checkpoint), .interruptedMigration(checkpoint))
    }

    func testTestOnlyLightweightAndCustomMigrationHarnessReopensStore() throws {
        let directory = temporaryDirectory("evolution")
        defer { try? fm.removeItem(at: directory) }
        let store = directory.appendingPathComponent("Migration.store")
        let id = UUID(uuidString: "13000000-0000-0000-0000-000000000901")!
        do {
            let value = Schema(versionedSchema: MigrationTestSchemaV1.self)
            let container = try ModelContainer(for: value, configurations: .init("Stage13EvolutionV1", schema: value, url: store, cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(MigrationTestSchemaV1.Item(id: id, name: "  Winter Coat  "))
            try context.save()
        }
        do {
            let container = try container(schema: MigrationTestSchemaV2.self, plan: MigrationTestLightweightPlan.self, store: store)
            let item = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<MigrationTestSchemaV2.Item>()).first)
            XCTAssertEqual(item.id, id); XCTAssertEqual(item.name, "  Winter Coat  "); XCTAssertNil(item.notes)
        }
        do {
            let container = try container(schema: MigrationTestSchemaV3.self, plan: MigrationTestCustomPlan.self, store: store)
            let item = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<MigrationTestSchemaV3.Item>()).first)
            XCTAssertEqual(item.id, id); XCTAssertEqual(item.name, "  Winter Coat  ")
            XCTAssertNil(item.notes); XCTAssertEqual(item.normalizedName, "winter coat")
        }
        let reopened = try container(schema: MigrationTestSchemaV3.self, plan: MigrationTestCustomPlan.self, store: store)
        XCTAssertEqual(try ModelContext(reopened).fetch(FetchDescriptor<MigrationTestSchemaV3.Item>()).first?.id, id)
    }

    func testV1LogicalFixtureBuildOpenReopenAndPreserveCrossFeatureData() throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "json"))
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        XCTAssertEqual(fixture?["fixtureVersion"] as? String, "1.0.0")
        XCTAssertEqual(fixture?["immutable"] as? Bool, true)

        let directory = temporaryDirectory("v1-fixture")
        defer { try? fm.removeItem(at: directory) }
        let store = directory.appendingPathComponent("WardrobeV1.store")
        do {
            let container = try productionV1Container(store: store)
            try Self.buildV1Fixture(in: container)
            try assertV1Fixture(container)
        }
        do {
            let container = try productionV1Container(store: store)
            try assertV1Fixture(container)
            XCTAssertTrue(try LibraryConsistencyValidator().validate(container: container).isEmpty)
        }
    }

    func testMigratedV1DeleteRulesPreserveSnapshotsAndCascadeChildren() throws {
        let container = try WardrobeModelContainerFactory.inMemory()
        try Self.buildV1Fixture(in: container)
        let repository = SwiftDataWardrobeRepository(container: container)
        let clothingID = Self.id(1)
        let outfitID = Self.id(30)
        let generationID = Self.id(40)
        try repository.deleteClothingItem(id: clothingID)
        XCTAssertNil(try XCTUnwrap(repository.outfit(id: outfitID)).items.first { $0.clothingItemID == clothingID }?.clothingItem)
        XCTAssertEqual(try XCTUnwrap(repository.generationRecord(id: generationID)).garmentInputs.first { $0.clothingItemID == clothingID }?.clothingNameSnapshot, "Future coat")
        try repository.deleteOutfit(id: outfitID)
        try repository.deleteGeneration(id: generationID)
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutfitItem>()).isEmpty)
        XCTAssertFalse(try context.fetch(FetchDescriptor<GenerationGarmentInput>()).contains { $0.generation.id == generationID })
    }

    func testConsistencyValidatorReportsAndNeverRepairsInvalidData() throws {
        let container = try WardrobeModelContainerFactory.inMemory()
        let context = ModelContext(container)
        let first = PersonProfile(id: Self.id(81), name: "One", isDefault: true)
        let second = PersonProfile(id: Self.id(82), name: "Two", isDefault: true, archivedAt: Date(timeIntervalSince1970: 1))
        let invalid = ClothingItem(id: Self.id(83), name: "Invalid", originalResourceID: "/Users/private/image.jpg")
        context.insert(first); context.insert(second); context.insert(invalid); try context.save()
        let issues = try LibraryConsistencyValidator().validate(container: container)
        XCTAssertTrue(issues.contains { $0.kind == .multipleDefaultPersons })
        XCTAssertTrue(issues.contains { $0.kind == .archivedDefaultPerson })
        XCTAssertTrue(issues.contains { $0.kind == .invalidResourceID })
        XCTAssertEqual(try context.fetch(FetchDescriptor<PersonProfile>()).filter(\.isDefault).count, 2)
    }

    func testInjectedMigrationFailureRollsBackAndOldV1StoreReopens() async throws {
        let directory = temporaryDirectory("rollback")
        defer { try? fm.removeItem(at: directory) }
        let store = directory.appendingPathComponent("WardrobeV1.store")
        do { let container = try productionV1Container(store: store); try Self.buildV1Fixture(in: container) }
        let checkpointURL = directory.appendingPathComponent("migration/checkpoint.json")
        let coordinator = LibraryMigrationCoordinator(checkpointURL: checkpointURL)
        let step = InjectedStorageMigrationStep(failValidation: true)
        do {
            try await coordinator.migrate(from: .current, to: .init(schemaVersion: .init(1, 0, 0), storageLayoutVersion: 2), step: step)
            XCTFail("Expected injected failure")
        } catch { XCTAssertEqual(error as? LibraryMigrationError, .migrationFailed) }
        let state = await step.state()
        XCTAssertFalse(state.0); XCTAssertTrue(state.1)
        XCTAssertFalse(fm.fileExists(atPath: checkpointURL.path))
        let reopened = try productionV1Container(store: store)
        try assertV1Fixture(reopened)
    }

    func testCheckpointBlocksHalfMigratedLibrary() async throws {
        let directory = temporaryDirectory("interrupted")
        defer { try? fm.removeItem(at: directory) }
        let checkpointURL = directory.appendingPathComponent("migration/checkpoint.json")
        let coordinator = LibraryMigrationCoordinator(checkpointURL: checkpointURL)
        let checkpoint = LibraryMigrationCheckpoint(source: .current, target: .init(schemaVersion: .init(1, 0, 0), storageLayoutVersion: 2), phase: .validating)
        try fm.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: checkpointURL)
        let storedCheckpoint = try await coordinator.checkpoint()
        XCTAssertEqual(storedCheckpoint, checkpoint)
        XCTAssertEqual(MigrationPreflight().evaluate(manifest: manifest(layout: 1), schemaVersion: .init(1, 0, 0), checkpoint: checkpoint), .interruptedMigration(checkpoint))
    }

    private func manifest(layout: Int) -> StorageLibraryManifest {
        .init(storageLayoutVersion: layout, libraryID: Self.id(99), createdAt: Date(timeIntervalSince1970: 0))
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("WardrobeStage13-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func productionV1Container(store: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WardrobeSchemaV1.self)
        return try ModelContainer(for: schema, migrationPlan: WardrobeMigrationPlan.self, configurations: .init("Stage13V1", schema: schema, url: store, cloudKitDatabase: .none))
    }

    private func container<S: VersionedSchema, P: SchemaMigrationPlan>(schema: S.Type, plan: P.Type, store: URL) throws -> ModelContainer {
        let value = Schema(versionedSchema: schema)
        return try ModelContainer(for: value, migrationPlan: plan, configurations: .init("Stage13Evolution", schema: value, url: store, cloudKitDatabase: .none))
    }

    private func assertV1Fixture(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ClothingItem>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PersonProfile>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PersonImage>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Outfit>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutfitItem>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GenerationRecord>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GenerationPersonInput>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GenerationGarmentInput>()).count, 3)
        let clothing = try XCTUnwrap(context.fetch(FetchDescriptor<ClothingItem>()).first { $0.id == Self.id(1) })
        XCTAssertEqual(clothing.categoryCode, "future-category")
        XCTAssertNil(clothing.notes); XCTAssertEqual(clothing.brand, "Archive Brand")
        let outfit = try XCTUnwrap(context.fetch(FetchDescriptor<Outfit>()).first)
        XCTAssertEqual(outfit.items.map(\.slotCode).sorted(), ["accessories", "accessories", "future-slot"])
        let generation = try XCTUnwrap(context.fetch(FetchDescriptor<GenerationRecord>()).first { $0.id == Self.id(41) })
        XCTAssertEqual(generation.statusCode, "future-status")
        XCTAssertEqual(generation.sourceGenerationID, Self.id(40))
        for raw in try SwiftDataWardrobeRepository(container: container).allPersistedResourceIDStrings() {
            XCTAssertNoThrow(try StorageResourceID(rawValue: raw)); XCTAssertFalse(raw.hasPrefix("/")); XCTAssertFalse(raw.contains(".."))
        }
    }

    private static func buildV1Fixture(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coat = ClothingItem(id: id(1), name: "Future coat", notes: nil, categoryCode: "future-category", brand: "Archive Brand", isFavorite: true, originalResourceID: resource(.garment, 1, .original(fileExtension: "heic")), processedResourceID: resource(.garment, 1, .processed), thumbnailResourceID: resource(.garment, 1, .thumbnail), archivedAt: date, createdAt: date)
        let top = ClothingItem(id: id(2), name: "Top", categoryCode: ClothingCategory.tops.rawValue, originalResourceID: resource(.garment, 2, .original(fileExtension: "jpg")), processedResourceID: resource(.garment, 2, .processed), thumbnailResourceID: resource(.garment, 2, .thumbnail), createdAt: date)
        let watch = ClothingItem(id: id(3), name: "Watch", categoryCode: ClothingCategory.accessories.rawValue, originalResourceID: resource(.garment, 3, .original(fileExtension: "png")), createdAt: date)
        let active = PersonProfile(id: id(10), name: "Default", isDefault: true, createdAt: date)
        let archived = PersonProfile(id: id(11), name: "Archived", archivedAt: date, createdAt: date)
        let primary = PersonImage(id: id(20), profile: active, isPrimary: true, originalResourceID: resource(.person, 20, .original(fileExtension: "jpg")), processedResourceID: resource(.person, 20, .processed), thumbnailResourceID: resource(.person, 20, .thumbnail), createdAt: date)
        let additional = PersonImage(id: id(21), profile: active, originalResourceID: resource(.person, 21, .original(fileExtension: "jpg")), createdAt: date.addingTimeInterval(1))
        active.images = [primary, additional]
        let outfit = Outfit(id: id(30), name: "Fixture Outfit", notes: "stable", isFavorite: true, createdAt: date)
        outfit.items = [
            OutfitItem(id: id(31), outfit: outfit, clothingItem: coat, clothingItemID: coat.id, clothingNameSnapshot: coat.name, thumbnailResourceIDSnapshot: coat.thumbnailResourceID, slotCode: "future-slot", sortOrder: 0, createdAt: date),
            OutfitItem(id: id(32), outfit: outfit, clothingItem: top, clothingItemID: top.id, clothingNameSnapshot: top.name, thumbnailResourceIDSnapshot: top.thumbnailResourceID, slotCode: TryOnSlot.accessories.rawValue, sortOrder: 0, createdAt: date),
            OutfitItem(id: id(33), outfit: outfit, clothingItem: nil, clothingItemID: id(333), clothingNameSnapshot: "Deleted scarf", thumbnailResourceIDSnapshot: resource(.garment, 3, .thumbnail), slotCode: TryOnSlot.accessories.rawValue, sortOrder: 1, createdAt: date),
        ]
        let succeeded = GenerationRecord(id: id(40), providerID: "mock", providerModelID: "fixture", statusCode: GenerationStatus.succeeded.rawValue, prompt: "prompt", optionsJSON: "{\"seed\":1}", resultResourceID: resource(.generation, 40, .generationResult(fileExtension: "png")), resultThumbnailResourceID: resource(.generation, 40, .thumbnail), attemptCount: 1, startedAt: date, completedAt: date.addingTimeInterval(2), createdAt: date)
        let failed = GenerationRecord(id: id(41), sourceGenerationID: id(40), providerID: "future-provider", statusCode: "future-status", prompt: "failed", optionsJSON: "{}", errorCode: "fixture", errorMessage: "safe", attemptCount: 1, createdAt: date)
        let cancelled = GenerationRecord(id: id(42), providerID: "mock", statusCode: GenerationStatus.cancelled.rawValue, prompt: "cancelled", optionsJSON: "{}", createdAt: date)
        succeeded.personInputs = [GenerationPersonInput(id: id(50), generation: succeeded, personProfile: active, personProfileID: active.id, personNameSnapshot: active.name, personImage: primary, personImageID: primary.id, resourceIDSnapshot: primary.processedResourceID!, sortOrder: 0, createdAt: date)]
        succeeded.garmentInputs = [GenerationGarmentInput(id: id(60), generation: succeeded, clothingItem: coat, clothingItemID: coat.id, clothingNameSnapshot: coat.name, categoryCodeSnapshot: coat.categoryCode, slotCode: "future-slot", resourceIDSnapshot: coat.processedResourceID!, sortOrder: 0, createdAt: date)]
        failed.personInputs = [GenerationPersonInput(id: id(51), generation: failed, personProfile: archived, personProfileID: archived.id, personNameSnapshot: archived.name, personImage: nil, personImageID: id(211), resourceIDSnapshot: additional.originalResourceID, sortOrder: 0, createdAt: date)]
        failed.garmentInputs = [GenerationGarmentInput(id: id(61), generation: failed, clothingItem: top, clothingItemID: top.id, clothingNameSnapshot: top.name, categoryCodeSnapshot: top.categoryCode, slotCode: TryOnSlot.upperBody.rawValue, resourceIDSnapshot: top.processedResourceID!, sortOrder: 0, createdAt: date)]
        cancelled.personInputs = [GenerationPersonInput(id: id(52), generation: cancelled, personProfile: active, personProfileID: active.id, personNameSnapshot: active.name, personImage: additional, personImageID: additional.id, resourceIDSnapshot: additional.originalResourceID, sortOrder: 0, createdAt: date)]
        cancelled.garmentInputs = [GenerationGarmentInput(id: id(62), generation: cancelled, clothingItem: watch, clothingItemID: watch.id, clothingNameSnapshot: watch.name, categoryCodeSnapshot: watch.categoryCode, slotCode: TryOnSlot.accessories.rawValue, resourceIDSnapshot: watch.originalResourceID, sortOrder: 0, createdAt: date)]
        context.insert(coat)
        context.insert(top)
        context.insert(watch)
        context.insert(active)
        context.insert(archived)
        context.insert(outfit)
        context.insert(succeeded)
        context.insert(failed)
        context.insert(cancelled)
        try context.save()
    }

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "13000000-0000-0000-0000-%012d", suffix))!
    }
    private static func resource(_ kind: StorageOwnerKind, _ suffix: Int, _ resourceKind: StorageResourceKind) -> String {
        try! StorageResourceID(owner: .init(kind: kind, id: id(suffix)), kind: resourceKind).rawValue
    }

    private static let frozenV1Contract = [
        "ClothingItem:archivedAt:Optional<Date>?,brand:Optional<String>?,categoryCode:String!,colorCodes:Array<String>!,createdAt:Date!,generationInputs>GenerationGarmentInput[nullify],id:UUID!,isFavorite:Bool!,materials:Array<String>!,name:String!,notes:Optional<String>?,originalResourceID:String!,outfitItems>OutfitItem[nullify],processedResourceID:Optional<String>?,seasonCodes:Array<String>!,styleCodes:Array<String>!,subcategoryCode:Optional<String>?,tags:Array<String>!,thumbnailResourceID:Optional<String>?,updatedAt:Date!",
        "GenerationGarmentInput:categoryCodeSnapshot:String!,clothingItem>ClothingItem[nullify],clothingItemID:UUID!,clothingNameSnapshot:String!,createdAt:Date!,generation>GenerationRecord[nullify],id:UUID!,resourceIDSnapshot:String!,slotCode:String!,sortOrder:Int!,updatedAt:Date!",
        "GenerationPersonInput:createdAt:Date!,generation>GenerationRecord[nullify],id:UUID!,personImage>PersonImage[nullify],personImageID:UUID!,personNameSnapshot:String!,personProfile>PersonProfile[nullify],personProfileID:UUID!,resourceIDSnapshot:String!,sortOrder:Int!,updatedAt:Date!",
        "GenerationRecord:attemptCount:Int!,completedAt:Optional<Date>?,createdAt:Date!,errorCode:Optional<String>?,errorMessage:Optional<String>?,garmentInputs>GenerationGarmentInput[cascade],id:UUID!,optionsJSON:String!,personInputs>GenerationPersonInput[cascade],prompt:String!,providerID:String!,providerModelID:Optional<String>?,providerRequestID:Optional<String>?,resultResourceID:Optional<String>?,resultThumbnailResourceID:Optional<String>?,sourceGenerationID:Optional<UUID>?,startedAt:Optional<Date>?,statusCode:String!,updatedAt:Date!",
        "Outfit:archivedAt:Optional<Date>?,coverResourceID:Optional<String>?,createdAt:Date!,id:UUID!,isFavorite:Bool!,items>OutfitItem[cascade],name:String!,notes:Optional<String>?,updatedAt:Date!",
        "OutfitItem:clothingItem>ClothingItem[nullify],clothingItemID:UUID!,clothingNameSnapshot:String!,createdAt:Date!,id:UUID!,outfit>Outfit[nullify],slotCode:String!,sortOrder:Int!,thumbnailResourceIDSnapshot:Optional<String>?,updatedAt:Date!",
        "PersonImage:createdAt:Date!,generationInputs>GenerationPersonInput[nullify],id:UUID!,isPrimary:Bool!,originalResourceID:String!,pixelHeight:Optional<Int>?,pixelWidth:Optional<Int>?,processedResourceID:Optional<String>?,profile>PersonProfile[nullify],thumbnailResourceID:Optional<String>?,updatedAt:Date!",
        "PersonProfile:archivedAt:Optional<Date>?,createdAt:Date!,generationInputs>GenerationPersonInput[nullify],id:UUID!,images>PersonImage[cascade],isDefault:Bool!,name:String!,notes:Optional<String>?,updatedAt:Date!",
    ]
}
