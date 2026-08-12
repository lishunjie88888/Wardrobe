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
    func clothingItems(matching query: ClothingQuery) throws -> [ClothingRecord]
    func insertAndSave(_ item: ClothingItem) throws
    func updateClothing(id: UUID, draft: ClothingDraft, at date: Date) throws -> ClothingRecord
    func setClothingFavorite(id: UUID, isFavorite: Bool, at date: Date) throws -> ClothingRecord
    func setClothingArchived(id: UUID, archived: Bool, at date: Date) throws -> ClothingRecord
    func clothingDeleteImpact(id: UUID) throws -> ClothingDeleteImpact
    func allPersistedResourceIDStrings() throws -> Set<String>
    func deleteClothingItem(id: UUID) throws
    func save() throws
}

@MainActor
protocol PersonRepository {
    func insert(_ profile: PersonProfile) throws
    func insert(_ image: PersonImage) throws
    func personProfile(id: UUID) throws -> PersonProfile?
    func personImage(id: UUID) throws -> PersonImage?
    func personProfiles(archive: PersonArchiveFilter) throws -> [PersonProfileRecord]
    func createPersonProfile(draft: PersonDraft, at date: Date) throws -> PersonProfileRecord
    func updatePersonProfile(id: UUID, draft: PersonDraft, at date: Date) throws -> PersonProfileRecord
    func setPersonProfileArchived(id: UUID, archived: Bool, at date: Date) throws -> PersonProfileRecord
    func insertPersonImageAndSave(_ image: PersonImage, at date: Date) throws -> PersonImageRecord
    func setDefaultPersonProfile(id: UUID, at date: Date) throws
    func setPrimaryPersonImage(id: UUID, for profileID: UUID, at date: Date) throws
    func defaultPersonReferenceSet() throws -> PersonReferenceSet?
    func personReferenceSet(profileID: UUID) throws -> PersonReferenceSet?
    func personImageDeleteImpact(id: UUID) throws -> PersonImageDeleteImpact
    func personProfileDeleteImpact(id: UUID) throws -> PersonProfileDeleteImpact
    func deletePersonImage(id: UUID, at date: Date) throws
    func deletePersonProfileAndSave(id: UUID) throws
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
    func allGenerationRecords() throws -> [GenerationRecord]
    func nonterminalGenerationRecords() throws -> [GenerationRecord]
    func transitionGeneration(id: UUID, to status: GenerationStatus, at date: Date) throws
    func deleteGeneration(id: UUID) throws
    func save() throws
}

typealias WardrobeRepository = ClothingRepository & PersonRepository & OutfitRepository & GenerationRepository
