import Foundation

enum WardrobeDataRules {
    static func validateGeneration(_ generation: GenerationRecord) throws {
        var occupiedSingleSlots = Set<TryOnSlot>()
        for input in generation.garmentInputs {
            let resolvedSlot = ResolvedCode<TryOnSlot>(input.slotCode)
            guard case let .known(slot) = resolvedSlot else {
                throw WardrobeRepositoryError.invalidGeneration(reason: "Unknown try-on slot: \(input.slotCode)")
            }
            guard slot.permitsMultipleItems || occupiedSingleSlots.insert(slot).inserted else {
                throw WardrobeRepositoryError.invalidGeneration(reason: "Only one item is allowed in \(slot.rawValue).")
            }
        }
    }

    static func validateOutfit(_ outfit: Outfit) throws {
        guard !outfit.items.isEmpty else {
            throw WardrobeRepositoryError.invalidOutfit(reason: "An outfit must contain at least one item.")
        }

        var occupiedSingleSlots = Set<TryOnSlot>()
        var accessoryOrders: [Int] = []
        for item in outfit.items {
            guard case let .known(slot) = item.resolvedSlot else {
                throw WardrobeRepositoryError.invalidOutfit(reason: "Unknown try-on slot: \(item.slotCode)")
            }
            guard slot.permitsMultipleItems || occupiedSingleSlots.insert(slot).inserted else {
                throw WardrobeRepositoryError.invalidOutfit(reason: "Only one item is allowed in \(slot.rawValue).")
            }
            if slot == .accessories { accessoryOrders.append(item.sortOrder) }
        }
        if accessoryOrders.sorted() != Array(0..<accessoryOrders.count) {
            throw WardrobeRepositoryError.invalidOutfit(reason: "Accessory sort order must be continuous.")
        }
    }

    static func validateTransition(from rawStatus: String, to next: GenerationStatus) throws {
        guard case let .known(current) = ResolvedCode<GenerationStatus>(rawStatus),
              current.canTransition(to: next)
        else {
            throw WardrobeRepositoryError.invalidGenerationTransition(from: rawStatus, to: next.rawValue)
        }
    }
}
