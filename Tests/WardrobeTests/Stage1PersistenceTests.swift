import SwiftData
import XCTest
@testable import Wardrobe

@MainActor
final class Stage1PersistenceTests: XCTestCase {
    private func makePersistence() throws -> (ModelContainer, SwiftDataWardrobeRepository) {
        let container = try WardrobeModelContainerFactory.inMemory()
        return (container, SwiftDataWardrobeRepository(container: container))
    }

    func testAllModelsPersistRefetchAndUpdate() throws {
        let (container, repository) = try makePersistence()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = createdAt.addingTimeInterval(60)
        let clothing = ClothingItem(
            name: "Jacket",
            categoryCode: ClothingCategory.outerwear.rawValue,
            originalResourceID: "garments/item/original.heic",
            createdAt: createdAt
        )
        let profile = PersonProfile(name: "Alex", createdAt: createdAt)
        let personImage = PersonImage(
            profile: profile,
            originalResourceID: "persons/image/original.jpg",
            createdAt: createdAt
        )
        profile.images.append(personImage)

        let outfit = Outfit(name: "Work", createdAt: createdAt)
        let outfitItem = OutfitItem(
            outfit: outfit,
            clothingItem: clothing,
            clothingItemID: clothing.id,
            clothingNameSnapshot: clothing.name,
            slotCode: TryOnSlot.outerwear.rawValue,
            createdAt: createdAt
        )
        outfit.items.append(outfitItem)

        let generation = GenerationRecord(providerID: "mock", createdAt: createdAt)
        let personInput = GenerationPersonInput(
            generation: generation,
            personProfile: profile,
            personProfileID: profile.id,
            personNameSnapshot: profile.name,
            personImage: personImage,
            personImageID: personImage.id,
            resourceIDSnapshot: personImage.originalResourceID,
            createdAt: createdAt
        )
        let garmentInput = GenerationGarmentInput(
            generation: generation,
            clothingItem: clothing,
            clothingItemID: clothing.id,
            clothingNameSnapshot: clothing.name,
            categoryCodeSnapshot: clothing.categoryCode,
            slotCode: TryOnSlot.outerwear.rawValue,
            resourceIDSnapshot: clothing.originalResourceID,
            createdAt: createdAt
        )
        generation.personInputs.append(personInput)
        generation.garmentInputs.append(garmentInput)

        try repository.insert(clothing)
        try repository.insert(profile)
        try repository.insert(outfit)
        try repository.insert(generation)
        try repository.save()

        let reloadedRepository = SwiftDataWardrobeRepository(container: container)
        let fetchedClothing = try XCTUnwrap(reloadedRepository.clothingItem(id: clothing.id))
        let fetchedProfile = try XCTUnwrap(reloadedRepository.personProfile(id: profile.id))
        let fetchedImage = try XCTUnwrap(reloadedRepository.personImage(id: personImage.id))
        let fetchedOutfit = try XCTUnwrap(reloadedRepository.outfit(id: outfit.id))
        let fetchedGeneration = try XCTUnwrap(reloadedRepository.generationRecord(id: generation.id))

        XCTAssertEqual(fetchedClothing.id, clothing.id)
        XCTAssertEqual(fetchedProfile.images.map(\.id), [personImage.id])
        XCTAssertEqual(fetchedImage.profile.id, profile.id)
        XCTAssertEqual(fetchedOutfit.items.map(\.id), [outfitItem.id])
        XCTAssertEqual(fetchedGeneration.personInputs.map(\.id), [personInput.id])
        XCTAssertEqual(fetchedGeneration.garmentInputs.map(\.id), [garmentInput.id])

        fetchedClothing.name = "Updated Jacket"
        fetchedClothing.markUpdated(at: updatedAt)
        fetchedProfile.name = "Updated Alex"
        fetchedProfile.markUpdated(at: updatedAt)
        fetchedImage.pixelWidth = 1_024
        fetchedImage.markUpdated(at: updatedAt)
        fetchedOutfit.name = "Updated Work"
        fetchedOutfit.markUpdated(at: updatedAt)
        let fetchedOutfitItem = try XCTUnwrap(fetchedOutfit.items.first)
        fetchedOutfitItem.sortOrder = 2
        fetchedOutfitItem.markUpdated(at: updatedAt)
        fetchedGeneration.prompt = "Updated prompt"
        fetchedGeneration.markUpdated(at: updatedAt)
        let fetchedPersonInput = try XCTUnwrap(fetchedGeneration.personInputs.first)
        fetchedPersonInput.personNameSnapshot = "Updated person snapshot"
        fetchedPersonInput.markUpdated(at: updatedAt)
        let fetchedGarmentInput = try XCTUnwrap(fetchedGeneration.garmentInputs.first)
        fetchedGarmentInput.clothingNameSnapshot = "Updated garment snapshot"
        fetchedGarmentInput.markUpdated(at: updatedAt)
        try reloadedRepository.save()

        let finalRepository = SwiftDataWardrobeRepository(container: container)
        let updatedClothing = try XCTUnwrap(finalRepository.clothingItem(id: clothing.id))
        let updatedProfile = try XCTUnwrap(finalRepository.personProfile(id: profile.id))
        let updatedImage = try XCTUnwrap(finalRepository.personImage(id: personImage.id))
        let updatedOutfit = try XCTUnwrap(finalRepository.outfit(id: outfit.id))
        let updatedGeneration = try XCTUnwrap(finalRepository.generationRecord(id: generation.id))
        XCTAssertEqual(updatedClothing.name, "Updated Jacket")
        XCTAssertEqual(updatedClothing.createdAt, createdAt)
        XCTAssertEqual(updatedClothing.updatedAt, updatedAt)
        XCTAssertEqual(updatedProfile.name, "Updated Alex")
        XCTAssertEqual(updatedProfile.updatedAt, updatedAt)
        XCTAssertEqual(updatedImage.pixelWidth, 1_024)
        XCTAssertEqual(updatedImage.updatedAt, updatedAt)
        XCTAssertEqual(updatedOutfit.name, "Updated Work")
        XCTAssertEqual(updatedOutfit.items.first?.sortOrder, 2)
        XCTAssertEqual(updatedOutfit.items.first?.updatedAt, updatedAt)
        XCTAssertEqual(updatedGeneration.prompt, "Updated prompt")
        XCTAssertEqual(updatedGeneration.updatedAt, updatedAt)
        XCTAssertEqual(updatedGeneration.personInputs.first?.personNameSnapshot, "Updated person snapshot")
        XCTAssertEqual(updatedGeneration.personInputs.first?.updatedAt, updatedAt)
        XCTAssertEqual(updatedGeneration.garmentInputs.first?.clothingNameSnapshot, "Updated garment snapshot")
        XCTAssertEqual(updatedGeneration.garmentInputs.first?.updatedAt, updatedAt)
    }

    func testPersonProfileAndOutfitCascadeDeleteTheirOwnedChildren() throws {
        let (container, repository) = try makePersistence()
        let profile = PersonProfile(name: "Profile")
        let image = PersonImage(profile: profile, originalResourceID: "persons/image/original.jpg")
        profile.images.append(image)
        try repository.insert(profile)

        let clothing = ClothingItem(name: "Top", originalResourceID: "garments/item/original.jpg")
        let outfit = Outfit(name: "Outfit")
        let item = OutfitItem(
            outfit: outfit,
            clothingItem: clothing,
            clothingItemID: clothing.id,
            clothingNameSnapshot: clothing.name,
            slotCode: TryOnSlot.upperBody.rawValue
        )
        outfit.items.append(item)
        try repository.insert(clothing)
        try repository.insert(outfit)
        try repository.save()

        try repository.deletePersonProfile(id: profile.id)
        try repository.deleteOutfit(id: outfit.id)

        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PersonImage>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutfitItem>()).isEmpty)
        XCTAssertNotNil(try repository.clothingItem(id: clothing.id))
    }

    func testSourceDeletionNullifiesRelationsAndPreservesSnapshots() throws {
        let (_, repository) = try makePersistence()
        let clothing = ClothingItem(name: "Top", originalResourceID: "garments/item/original.jpg")
        let profile = PersonProfile(name: "Profile")
        let image = PersonImage(profile: profile, originalResourceID: "persons/image/original.jpg")
        profile.images.append(image)

        let outfit = Outfit(name: "Outfit")
        let outfitItem = OutfitItem(
            outfit: outfit,
            clothingItem: clothing,
            clothingItemID: clothing.id,
            clothingNameSnapshot: "Top snapshot",
            slotCode: TryOnSlot.upperBody.rawValue
        )
        outfit.items.append(outfitItem)

        let generation = GenerationRecord(providerID: "mock")
        let personInput = GenerationPersonInput(
            generation: generation,
            personProfile: profile,
            personProfileID: profile.id,
            personNameSnapshot: "Profile snapshot",
            personImage: image,
            personImageID: image.id,
            resourceIDSnapshot: "persons/snapshot/processed.png"
        )
        let garmentInput = GenerationGarmentInput(
            generation: generation,
            clothingItem: clothing,
            clothingItemID: clothing.id,
            clothingNameSnapshot: "Top snapshot",
            slotCode: TryOnSlot.upperBody.rawValue,
            resourceIDSnapshot: "garments/snapshot/processed.png"
        )
        generation.personInputs.append(personInput)
        generation.garmentInputs.append(garmentInput)

        try repository.insert(clothing)
        try repository.insert(profile)
        try repository.insert(outfit)
        try repository.insert(generation)
        try repository.save()

        try repository.deleteClothingItem(id: clothing.id)
        try repository.deletePersonProfile(id: profile.id)

        let reloadedOutfit = try XCTUnwrap(repository.outfit(id: outfit.id))
        let reloadedGeneration = try XCTUnwrap(repository.generationRecord(id: generation.id))
        XCTAssertNil(try XCTUnwrap(reloadedOutfit.items.first).clothingItem)
        XCTAssertEqual(reloadedOutfit.items.first?.clothingItemID, clothing.id)
        XCTAssertEqual(reloadedOutfit.items.first?.clothingNameSnapshot, "Top snapshot")
        XCTAssertNil(reloadedGeneration.garmentInputs.first?.clothingItem)
        XCTAssertEqual(reloadedGeneration.garmentInputs.first?.resourceIDSnapshot, "garments/snapshot/processed.png")
        XCTAssertNil(reloadedGeneration.personInputs.first?.personProfile)
        XCTAssertNil(reloadedGeneration.personInputs.first?.personImage)
        XCTAssertEqual(reloadedGeneration.personInputs.first?.resourceIDSnapshot, "persons/snapshot/processed.png")
    }

    func testDefaultsStableCodesUUIDAndTimestamps() {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = ClothingItem(id: id, originalResourceID: "garments/item/original.jpg", createdAt: createdAt)

        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.name, "")
        XCTAssertEqual(item.categoryCode, ClothingCategory.other.rawValue)
        XCTAssertEqual(item.colorCodes, [])
        XCTAssertFalse(item.isFavorite)
        XCTAssertNil(item.archivedAt)
        XCTAssertEqual(item.createdAt, createdAt)
        XCTAssertEqual(item.updatedAt, createdAt)

        item.categoryCode = "future_category"
        XCTAssertEqual(item.resolvedCategory, .unknown("future_category"))
        XCTAssertEqual(item.resolvedCategory.rawValue, "future_category")
        XCTAssertEqual(ResolvedCode<ClothingSubcategory>("future_subcategory").rawValue, "future_subcategory")
        XCTAssertEqual(ResolvedCode<Season>("future_season").rawValue, "future_season")
        XCTAssertEqual(ResolvedCode<StyleTag>("future_style").rawValue, "future_style")
        XCTAssertEqual(ResolvedCode<TryOnSlot>("future_slot").rawValue, "future_slot")
        XCTAssertEqual(ResolvedCode<GenerationStatus>("future_status").rawValue, "future_status")
    }

    func testDefaultPersonAndPrimaryImageUniqueness() throws {
        let (container, repository) = try makePersistence()
        let first = PersonProfile(name: "First")
        let second = PersonProfile(name: "Second")
        let firstImage = PersonImage(profile: first, originalResourceID: "persons/one/original.jpg")
        let secondImage = PersonImage(profile: first, originalResourceID: "persons/two/original.jpg")
        first.images.append(contentsOf: [firstImage, secondImage])
        try repository.insert(first)
        try repository.insert(second)
        try repository.save()

        try repository.setDefaultPersonProfile(id: first.id, at: .now)
        try repository.setDefaultPersonProfile(id: second.id, at: .now)
        try repository.setPrimaryPersonImage(id: firstImage.id, for: first.id, at: .now)
        try repository.setPrimaryPersonImage(id: secondImage.id, for: first.id, at: .now)

        let context = ModelContext(container)
        let profiles = try context.fetch(FetchDescriptor<PersonProfile>())
        let images = try context.fetch(FetchDescriptor<PersonImage>())
        XCTAssertEqual(profiles.filter(\.isDefault).map(\.id), [second.id])
        XCTAssertEqual(images.filter(\.isPrimary).map(\.id), [secondImage.id])
    }

    func testTryOnSlotConstraintsAreEnforcedByRepository() throws {
        let (_, repository) = try makePersistence()
        let clothing = ClothingItem(name: "Top", originalResourceID: "garments/item/original.jpg")
        let invalidOutfit = Outfit(name: "Invalid")
        invalidOutfit.items = [
            OutfitItem(outfit: invalidOutfit, clothingItem: clothing, clothingItemID: clothing.id, slotCode: TryOnSlot.upperBody.rawValue),
            OutfitItem(outfit: invalidOutfit, clothingItem: clothing, clothingItemID: clothing.id, slotCode: TryOnSlot.upperBody.rawValue),
        ]

        XCTAssertThrowsError(try repository.insert(invalidOutfit)) { error in
            guard case WardrobeRepositoryError.invalidOutfit = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let validOutfit = Outfit(name: "Accessories")
        validOutfit.items = [
            OutfitItem(outfit: validOutfit, clothingItem: clothing, clothingItemID: clothing.id, slotCode: TryOnSlot.accessories.rawValue, sortOrder: 0),
            OutfitItem(outfit: validOutfit, clothingItem: clothing, clothingItemID: clothing.id, slotCode: TryOnSlot.accessories.rawValue, sortOrder: 1),
        ]
        XCTAssertNoThrow(try repository.insert(validOutfit))
    }

    func testGenerationTerminalStateCannotReturnToRunning() throws {
        let (_, repository) = try makePersistence()
        let record = GenerationRecord(providerID: "mock")
        try repository.insert(record)
        try repository.save()
        try repository.transitionGeneration(id: record.id, to: .preparing, at: .now)
        try repository.transitionGeneration(id: record.id, to: .running, at: .now)
        try repository.transitionGeneration(id: record.id, to: .succeeded, at: .now)

        XCTAssertThrowsError(try repository.transitionGeneration(id: record.id, to: .running, at: .now)) {
            XCTAssertEqual(
                $0 as? WardrobeRepositoryError,
                .invalidGenerationTransition(from: "succeeded", to: "running")
            )
        }
    }

    func testGenerationTryOnSlotConstraintsAreEnforcedByRepository() throws {
        let (_, repository) = try makePersistence()
        let clothing = ClothingItem(name: "Top", originalResourceID: "garments/item/original.jpg")
        let generation = GenerationRecord(providerID: "mock")
        generation.garmentInputs = [
            GenerationGarmentInput(
                generation: generation,
                clothingItem: clothing,
                clothingItemID: clothing.id,
                slotCode: TryOnSlot.upperBody.rawValue,
                resourceIDSnapshot: clothing.originalResourceID
            ),
            GenerationGarmentInput(
                generation: generation,
                clothingItem: clothing,
                clothingItemID: clothing.id,
                slotCode: TryOnSlot.upperBody.rawValue,
                resourceIDSnapshot: clothing.originalResourceID
            ),
        ]

        XCTAssertThrowsError(try repository.insert(generation)) { error in
            guard case WardrobeRepositoryError.invalidGeneration = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testV1SchemaAndMigrationBaselineAreExplicit() {
        XCTAssertEqual(WardrobeSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(WardrobeSchemaV1.models.count, 8)
        XCTAssertEqual(WardrobeMigrationPlan.schemas.count, 1)
        XCTAssertTrue(WardrobeMigrationPlan.stages.isEmpty)
    }
}
