import Foundation

enum WardrobeRepositoryError: Error, Equatable {
    case modelNotFound(model: String, id: UUID)
    case invalidPersonSelection(reason: String)
    case invalidOutfit(reason: String)
    case invalidGeneration(reason: String)
    case invalidGenerationTransition(from: String, to: String)
}

@MainActor
protocol ClothingRepository {
    func insert(_ item: ClothingItem) throws
    func clothingItem(id: UUID) throws -> ClothingItem?
    func allClothingItems() throws -> [ClothingItem]
    func deleteClothingItem(id: UUID) throws
    func save() throws
}

@MainActor
protocol PersonRepository {
    func insert(_ profile: PersonProfile) throws
    func insert(_ image: PersonImage) throws
    func personProfile(id: UUID) throws -> PersonProfile?
    func personImage(id: UUID) throws -> PersonImage?
    func setDefaultPersonProfile(id: UUID, at date: Date) throws
    func setPrimaryPersonImage(id: UUID, for profileID: UUID, at date: Date) throws
    func deletePersonProfile(id: UUID) throws
    func save() throws
}

@MainActor
protocol OutfitRepository {
    func insert(_ outfit: Outfit) throws
    func outfit(id: UUID) throws -> Outfit?
    func deleteOutfit(id: UUID) throws
    func save() throws
}

@MainActor
protocol GenerationRepository {
    func insert(_ record: GenerationRecord) throws
    func generationRecord(id: UUID) throws -> GenerationRecord?
    func transitionGeneration(id: UUID, to status: GenerationStatus, at date: Date) throws
    func deleteGeneration(id: UUID) throws
    func save() throws
}

typealias WardrobeRepository = ClothingRepository & PersonRepository & OutfitRepository & GenerationRepository
