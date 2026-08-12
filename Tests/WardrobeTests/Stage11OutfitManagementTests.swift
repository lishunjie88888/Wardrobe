import Foundation
import SwiftData
import XCTest
@testable import Wardrobe

@MainActor
final class Stage11OutfitManagementTests: XCTestCase {
    func testSaveSingleAndMultipleSlotsPersistsNormalizedDraftAndSnapshots() throws {
        let fixture = try makeFixture()
        let upper = try fixture.insertClothing(name: "白衬衫", category: .tops, thumbnail: true)
        let shoes = try fixture.insertClothing(name: "皮鞋", category: .footwear, thumbnail: false)
        var session = TryOnSession()
        session.add(clothingID: upper.id, to: .upperBody)
        session.add(clothingID: shoes.id, to: .footwear)

        let saved = try fixture.service.save(session: session, draft: OutfitDraft(name: "  通勤  ", notes: "   ", isFavorite: true), at: fixture.date(10))

        XCTAssertEqual(saved.draft.name, "通勤")
        XCTAssertNil(saved.draft.notes)
        XCTAssertTrue(saved.draft.isFavorite)
        XCTAssertEqual(saved.items.map(\.slotCode), [TryOnSlot.upperBody.rawValue, TryOnSlot.footwear.rawValue])
        XCTAssertEqual(saved.items.first?.clothingNameSnapshot, "白衬衫")
        XCTAssertEqual(saved.items.first?.thumbnailResourceIDSnapshot?.rawValue, upper.thumbnailResourceID)
    }

    func testAccessoriesSaveAndLoadPreserveOrder() throws {
        let fixture = try makeFixture()
        let first = try fixture.insertClothing(name: "帽子", category: .accessories)
        let second = try fixture.insertClothing(name: "包", category: .accessories)
        var session = TryOnSession()
        session.add(clothingID: first.id, to: .accessories)
        session.add(clothingID: second.id, to: .accessories)
        let saved = try fixture.service.save(session: session, draft: OutfitDraft())

        XCTAssertEqual(saved.items.map(\.sortOrder), [0, 1])
        let load = try fixture.service.preflightLoad(id: saved.id)
        XCTAssertEqual(load.availableItems.map(\.clothingItemID), [first.id, second.id])
    }

    func testEmptyDuplicateSingleSlotInvalidSlotAndAccessoryGapAreRejected() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(try fixture.service.save(session: TryOnSession(), draft: OutfitDraft())) {
            XCTAssertEqual($0 as? OutfitServiceError, .emptyOutfit)
        }
        let first = try fixture.insertClothing(name: "一", category: .tops)
        let second = try fixture.insertClothing(name: "二", category: .tops)
        XCTAssertThrowsError(try fixture.service.create(draft: OutfitDraft(), items: [
            .init(clothingItemID: first.id, slotCode: TryOnSlot.upperBody.rawValue, sortOrder: 0),
            .init(clothingItemID: second.id, slotCode: TryOnSlot.upperBody.rawValue, sortOrder: 0),
        ]))
        XCTAssertThrowsError(try fixture.service.create(draft: OutfitDraft(), items: [.init(clothingItemID: first.id, slotCode: "future", sortOrder: 0)]))
        XCTAssertThrowsError(try fixture.service.create(draft: OutfitDraft(), items: [.init(clothingItemID: first.id, slotCode: TryOnSlot.accessories.rawValue, sortOrder: 2)]))
    }

    func testQuerySearchFiltersSortsAndUsesStableTieBreak() throws {
        let fixture = try makeFixture()
        let one = try fixture.insertClothing(name: "衬衫", category: .tops)
        let two = try fixture.insertClothing(name: "裤子", category: .bottoms)
        let a = try fixture.service.create(draft: OutfitDraft(name: "Alpha", notes: "office", isFavorite: false), items: [.init(clothingItemID: one.id, slotCode: "upper_body", sortOrder: 0)], at: fixture.date(10))
        let b = try fixture.service.create(draft: OutfitDraft(name: "Beta", notes: "weekend", isFavorite: true), items: [.init(clothingItemID: two.id, slotCode: "lower_body", sortOrder: 0)], at: fixture.date(10))
        _ = try fixture.service.setArchived(id: a.id, archived: true, at: fixture.date(20))

        var query = OutfitQuery(searchText: "weekend", archive: .all)
        XCTAssertEqual(try fixture.service.outfits(matching: query).map(\.id), [b.id])
        query = OutfitQuery(favoritesOnly: true, archive: .all)
        XCTAssertEqual(try fixture.service.outfits(matching: query).map(\.id), [b.id])
        query = OutfitQuery(archive: .archived)
        XCTAssertEqual(try fixture.service.outfits(matching: query).map(\.id), [a.id])
        query = OutfitQuery(archive: .all, sort: .name)
        XCTAssertEqual(try fixture.service.outfits(matching: query).map(\.id), [a.id, b.id])
        query = OutfitQuery(archive: .all, sort: .newest)
        XCTAssertEqual(try fixture.service.outfits(matching: query).map(\.id), [a.id, b.id].sorted { $0.uuidString < $1.uuidString })
    }

    func testEditFavoriteArchiveRestoreDoNotRewriteSnapshots() throws {
        let fixture = try makeFixture()
        let clothing = try fixture.insertClothing(name: "原名称", category: .outerwear, thumbnail: true)
        let saved = try fixture.service.create(draft: OutfitDraft(), items: [.init(clothingItemID: clothing.id, slotCode: "outerwear", sortOrder: 0)])
        let snapshot = saved.items[0]
        _ = try fixture.service.update(id: saved.id, draft: OutfitDraft(name: "新名称", notes: "备注", isFavorite: false))
        _ = try fixture.service.setFavorite(id: saved.id, isFavorite: true)
        XCTAssertTrue(try fixture.service.setArchived(id: saved.id, archived: true).isArchived)
        XCTAssertFalse(try fixture.service.setArchived(id: saved.id, archived: false).isArchived)
        let reloaded = try XCTUnwrap(fixture.service.outfit(id: saved.id))
        XCTAssertEqual(reloaded.items[0].clothingNameSnapshot, snapshot.clothingNameSnapshot)
        XCTAssertEqual(reloaded.items[0].thumbnailResourceIDSnapshot, snapshot.thumbnailResourceIDSnapshot)
        XCTAssertEqual(reloaded.items[0].clothingItemID, snapshot.clothingItemID)
    }

    func testCurrentRenameArchiveDeleteAndResourceReferenceSemantics() throws {
        let fixture = try makeFixture()
        let clothing = try fixture.insertClothing(name: "旧名称", category: .tops, thumbnail: true)
        let saved = try fixture.service.create(draft: OutfitDraft(), items: [.init(clothingItemID: clothing.id, slotCode: "upper_body", sortOrder: 0)])
        var draft = try XCTUnwrap(fixture.repository.clothingItems(matching: ClothingQuery()).first).draft
        draft.name = "当前名称"
        _ = try fixture.repository.updateClothing(id: clothing.id, draft: draft, at: fixture.date(20))
        XCTAssertEqual(try fixture.service.outfit(id: saved.id)?.items[0].displayName, "当前名称")
        _ = try fixture.repository.setClothingArchived(id: clothing.id, archived: true, at: fixture.date(21))
        XCTAssertEqual(try fixture.service.preflightLoad(id: saved.id).unavailableItems[0].reason, .archived)
        _ = try fixture.repository.setClothingArchived(id: clothing.id, archived: false, at: fixture.date(22))
        try fixture.repository.deleteClothingItem(id: clothing.id)
        let missing = try XCTUnwrap(fixture.service.outfit(id: saved.id)).items[0]
        XCTAssertFalse(missing.hasCurrentClothing)
        XCTAssertEqual(missing.displayName, "旧名称")
        XCTAssertTrue(try fixture.repository.allPersistedResourceIDStrings().contains(try XCTUnwrap(clothing.thumbnailResourceID)))
        XCTAssertEqual(try fixture.service.preflightLoad(id: saved.id).unavailableItems[0].reason, .missing)
    }

    func testPreflightClassifiesAvailableInvalidAndIncompatibleWithoutSubstitution() throws {
        let fixture = try makeFixture()
        let available = try fixture.insertClothing(name: "上衣", category: .tops)
        let incompatible = try fixture.insertClothing(name: "鞋", category: .footwear)
        let invalid = try fixture.insertClothing(name: "外套", category: .outerwear)
        let saved = try fixture.service.create(draft: OutfitDraft(), items: [
            .init(clothingItemID: available.id, slotCode: "upper_body", sortOrder: 0),
            .init(clothingItemID: incompatible.id, slotCode: "footwear", sortOrder: 0),
            .init(clothingItemID: invalid.id, slotCode: "outerwear", sortOrder: 0),
        ])
        incompatible.categoryCode = ClothingCategory.tops.rawValue
        try XCTUnwrap(fixture.repository.outfit(id: saved.id)).items.first { $0.clothingItemID == invalid.id }?.slotCode = "future_slot"
        try fixture.repository.save()

        let result = try fixture.service.preflightLoad(id: saved.id)
        XCTAssertEqual(result.availableItems.map(\.clothingItemID), [available.id])
        XCTAssertEqual(Set(result.unavailableItems.map(\.reason)), [.invalidSlot, .incompatible])
        XCTAssertFalse(result.availableItems.contains { $0.clothingItemID == incompatible.id || $0.clothingItemID == invalid.id })
    }

    func testNoAvailableItemsIsBlockedWithoutChangingCurrentSession() throws {
        let fixture = try makeFixture()
        let archived = try fixture.insertClothing(name: "归档衣物", category: .tops)
        let saved = try fixture.service.create(draft: OutfitDraft(), items: [.init(clothingItemID: archived.id, slotCode: "upper_body", sortOrder: 0)])
        _ = try fixture.repository.setClothingArchived(id: archived.id, archived: true, at: fixture.date(20))
        let result = try fixture.service.preflightLoad(id: saved.id)
        XCTAssertFalse(result.canLoad)
        var session = TryOnSession()
        let existing = UUID()
        session.add(clothingID: existing, to: .footwear)
        if result.canLoad { session.replaceGarments(with: result.availableItems) }
        XCTAssertEqual(session.garmentIDs(in: .footwear), [existing])
    }

    func testTryOnReplacePreservesPersonAndRestoresExactSlots() {
        var session = TryOnSession(personProfileID: UUID(), selectedPersonImageIDs: [UUID()])
        let profile = session.personProfileID
        let images = session.selectedPersonImageIDs
        session.add(clothingID: UUID(), to: .upperBody)
        let shoe = UUID(), bag = UUID()
        session.replaceGarments(with: [
            .init(id: UUID(), clothingItemID: shoe, slot: .footwear, sortOrder: 0),
            .init(id: UUID(), clothingItemID: bag, slot: .accessories, sortOrder: 0),
        ])
        XCTAssertEqual(session.personProfileID, profile)
        XCTAssertEqual(session.selectedPersonImageIDs, images)
        XCTAssertEqual(session.garmentIDs(in: .footwear), [shoe])
        XCTAssertEqual(session.garmentIDs(in: .accessories), [bag])
        XCTAssertTrue(session.garmentIDs(in: .upperBody).isEmpty)
    }

    func testPermanentDeleteCascadesItemsButKeepsClothingPersonAndGeneration() throws {
        let fixture = try makeFixture()
        let clothing = try fixture.insertClothing(name: "保留衣物", category: .tops)
        let saved = try fixture.service.create(draft: OutfitDraft(), items: [.init(clothingItemID: clothing.id, slotCode: "upper_body", sortOrder: 0)])
        let profile = PersonProfile(name: "保留人物")
        try fixture.repository.insert(profile)
        let generation = GenerationRecord(providerID: "mock")
        try fixture.repository.insert(generation)
        try fixture.repository.save()
        try fixture.service.permanentlyDelete(id: saved.id)
        XCTAssertNil(try fixture.repository.outfit(id: saved.id))
        XCTAssertNotNil(try fixture.repository.clothingItem(id: clothing.id))
        XCTAssertNotNil(try fixture.repository.personProfile(id: profile.id))
        XCTAssertNotNil(try fixture.repository.generationRecord(id: generation.id))
    }

    func testDiskRepositoryCanReadOutfitAfterRecreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WardrobeStage11-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var outfitID: UUID!
        do {
            let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.production(databaseDirectory: root))
            let clothing = ClothingItem(name: "持久衣物", categoryCode: "tops", originalResourceID: garmentResource(UUID()).rawValue)
            try repository.insert(clothing); try repository.save()
            outfitID = try OutfitService(repository: repository).create(draft: OutfitDraft(name: "持久穿搭"), items: [.init(clothingItemID: clothing.id, slotCode: "upper_body", sortOrder: 0)]).id
        }
        let rebuilt = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.production(databaseDirectory: root))
        XCTAssertEqual(try OutfitService(repository: rebuilt).outfit(id: outfitID)?.draft.name, "持久穿搭")
    }
}

@MainActor
private struct OutfitFixture {
    let repository: SwiftDataWardrobeRepository
    let service: OutfitService
    func date(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: value) }
    func insertClothing(name: String, category: ClothingCategory, thumbnail: Bool = false) throws -> ClothingItem {
        let id = UUID()
        let item = ClothingItem(
            id: id,
            name: name,
            categoryCode: category.rawValue,
            originalResourceID: garmentResource(id).rawValue,
            thumbnailResourceID: thumbnail ? try StorageResourceID(owner: .init(kind: .garment, id: id), kind: .thumbnail).rawValue : nil
        )
        try repository.insert(item); try repository.save()
        return item
    }
}

@MainActor
private func makeFixture() throws -> OutfitFixture {
    let repository = SwiftDataWardrobeRepository(container: try WardrobeModelContainerFactory.inMemory())
    return OutfitFixture(repository: repository, service: OutfitService(repository: repository))
}

private func garmentResource(_ id: UUID) -> StorageResourceID {
    try! StorageResourceID(owner: StorageOwner(kind: .garment, id: id), kind: .original(fileExtension: "jpg"))
}
