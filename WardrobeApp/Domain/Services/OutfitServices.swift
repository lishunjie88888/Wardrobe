import Foundation

@MainActor
protocol OutfitPersisting {
    func outfits(matching query: OutfitQuery) throws -> [OutfitRecord]
    func outfitRecord(id: UUID) throws -> OutfitRecord?
    func createOutfit(draft: OutfitDraft, items: [OutfitCreationItem], at date: Date) throws -> OutfitRecord
    func updateOutfit(id: UUID, draft: OutfitDraft, at date: Date) throws -> OutfitRecord
    func setOutfitFavorite(id: UUID, isFavorite: Bool, at date: Date) throws -> OutfitRecord
    func setOutfitArchived(id: UUID, archived: Bool, at date: Date) throws -> OutfitRecord
    func deleteOutfit(id: UUID) throws
}

extension SwiftDataWardrobeRepository: OutfitPersisting {}

@MainActor
final class OutfitService {
    private let repository: any OutfitPersisting
    private let mapper = ClothingToTryOnSlotMapper()

    init(repository: any OutfitPersisting) { self.repository = repository }

    func outfits(matching query: OutfitQuery = OutfitQuery()) throws -> [OutfitRecord] {
        try repository.outfits(matching: query)
    }

    func outfit(id: UUID) throws -> OutfitRecord? { try repository.outfitRecord(id: id) }

    func save(session: TryOnSession, draft: OutfitDraft, at date: Date = .now) throws -> OutfitRecord {
        var inputs: [OutfitCreationItem] = []
        for slot in TryOnSlot.allCases {
            for (index, clothingID) in session.garmentIDs(in: slot).enumerated() {
                inputs.append(OutfitCreationItem(clothingItemID: clothingID, slotCode: slot.rawValue, sortOrder: index))
            }
        }
        try Self.validateCreationItems(inputs)
        return try repository.createOutfit(draft: draft.normalized(), items: inputs, at: date)
    }

    func create(draft: OutfitDraft, items: [OutfitCreationItem], at date: Date = .now) throws -> OutfitRecord {
        try Self.validateCreationItems(items)
        return try repository.createOutfit(draft: draft.normalized(), items: items, at: date)
    }

    func update(id: UUID, draft: OutfitDraft, at date: Date = .now) throws -> OutfitRecord {
        try repository.updateOutfit(id: id, draft: draft.normalized(), at: date)
    }

    func setFavorite(id: UUID, isFavorite: Bool, at date: Date = .now) throws -> OutfitRecord {
        try repository.setOutfitFavorite(id: id, isFavorite: isFavorite, at: date)
    }

    func setArchived(id: UUID, archived: Bool, at date: Date = .now) throws -> OutfitRecord {
        try repository.setOutfitArchived(id: id, archived: archived, at: date)
    }

    func permanentlyDelete(id: UUID) throws { try repository.deleteOutfit(id: id) }

    func preflightLoad(id: UUID) throws -> OutfitLoadResult {
        guard let outfit = try repository.outfitRecord(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "Outfit", id: id)
        }
        var available: [OutfitLoadItem] = []
        var unavailable: [OutfitUnavailableItem] = []
        for item in outfit.items {
            let reason: OutfitUnavailableReason?
            if !item.hasCurrentClothing { reason = .missing }
            else if !item.currentClothingIsActive { reason = .archived }
            else if item.resolvedSlot == nil { reason = .invalidSlot }
            else if case let .supported(mapped) = mapper.slot(for: item.currentCategoryCode ?? ""), mapped == item.resolvedSlot {
                reason = nil
            } else { reason = .incompatible }

            if let reason {
                unavailable.append(.init(id: item.id, name: item.displayName, slotCode: item.slotCode, reason: reason))
            } else if let slot = item.resolvedSlot {
                available.append(.init(id: item.id, clothingItemID: item.clothingItemID, slot: slot, sortOrder: item.sortOrder))
            }
        }
        available.sort(by: Self.loadOrder)
        return OutfitLoadResult(outfitID: outfit.id, outfitName: outfit.draft.name, availableItems: available, unavailableItems: unavailable)
    }

    private static func validateCreationItems(_ items: [OutfitCreationItem]) throws {
        guard !items.isEmpty else { throw OutfitServiceError.emptyOutfit }
        var occupied = Set<TryOnSlot>()
        var clothingIDs = Set<UUID>()
        for item in items {
            guard let slot = TryOnSlot(rawValue: item.slotCode) else { throw OutfitServiceError.invalidSlot(item.slotCode) }
            guard clothingIDs.insert(item.clothingItemID).inserted else { throw OutfitServiceError.duplicateClothing(item.clothingItemID) }
            if !slot.permitsMultipleItems, !occupied.insert(slot).inserted { throw OutfitServiceError.duplicateSingleSlot(slot) }
        }
        let accessories = items.filter { $0.slotCode == TryOnSlot.accessories.rawValue }.sorted { $0.sortOrder < $1.sortOrder }
        guard accessories.map(\.sortOrder) == Array(0..<accessories.count) else {
            throw OutfitServiceError.invalidSlot(TryOnSlot.accessories.rawValue)
        }
    }

    private static func loadOrder(_ left: OutfitLoadItem, _ right: OutfitLoadItem) -> Bool {
        let leftSlot = TryOnSlot.allCases.firstIndex(of: left.slot) ?? Int.max
        let rightSlot = TryOnSlot.allCases.firstIndex(of: right.slot) ?? Int.max
        if leftSlot != rightSlot { return leftSlot < rightSlot }
        if left.sortOrder != right.sortOrder { return left.sortOrder < right.sortOrder }
        return left.id.uuidString < right.id.uuidString
    }
}
