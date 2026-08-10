import Foundation
import SwiftData

enum WardrobeModelContainerFactory {
    @MainActor
    static func production(databaseDirectory: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WardrobeSchemaV1.self)
        let configuration = ModelConfiguration(
            "WardrobeV1",
            schema: schema,
            url: databaseDirectory.appendingPathComponent("WardrobeV1.store"),
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: WardrobeMigrationPlan.self,
            configurations: configuration
        )
    }

    @MainActor
    static func inMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: WardrobeSchemaV1.self)
        let configuration = ModelConfiguration(
            "WardrobeV1Tests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: WardrobeMigrationPlan.self,
            configurations: configuration
        )
    }
}

@MainActor
final class SwiftDataWardrobeRepository: WardrobeRepository {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func insert(_ item: ClothingItem) throws { context.insert(item) }

    func clothingItem(id: UUID) throws -> ClothingItem? {
        let descriptor = FetchDescriptor<ClothingItem>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func allClothingItems() throws -> [ClothingItem] {
        try context.fetch(FetchDescriptor<ClothingItem>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func deleteClothingItem(id: UUID) throws {
        guard let item = try clothingItem(id: id) else { return }
        context.delete(item)
        try context.save()
    }

    func insert(_ profile: PersonProfile) throws {
        guard profile.archivedAt == nil || !profile.isDefault else {
            throw WardrobeRepositoryError.invalidPersonSelection(reason: "An archived profile cannot be the default.")
        }
        guard profile.images.filter(\.isPrimary).count <= 1 else {
            throw WardrobeRepositoryError.invalidPersonSelection(reason: "A profile can have at most one primary image.")
        }
        if profile.isDefault {
            let profiles = try context.fetch(FetchDescriptor<PersonProfile>())
            for existingProfile in profiles where existingProfile.archivedAt == nil {
                existingProfile.setDefault(false)
            }
        }
        context.insert(profile)
    }

    func insert(_ image: PersonImage) throws {
        if image.isPrimary {
            let images = try context.fetch(FetchDescriptor<PersonImage>())
            for existingImage in images where existingImage.profile.id == image.profile.id {
                existingImage.setPrimary(false)
            }
            for sibling in image.profile.images where sibling.id != image.id {
                sibling.setPrimary(false)
            }
        }
        context.insert(image)
    }

    func personProfile(id: UUID) throws -> PersonProfile? {
        let descriptor = FetchDescriptor<PersonProfile>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func personImage(id: UUID) throws -> PersonImage? {
        let descriptor = FetchDescriptor<PersonImage>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func setDefaultPersonProfile(id: UUID, at date: Date = .now) throws {
        let profiles = try context.fetch(FetchDescriptor<PersonProfile>())
        guard profiles.contains(where: { $0.id == id && $0.archivedAt == nil }) else {
            throw WardrobeRepositoryError.modelNotFound(model: "PersonProfile", id: id)
        }
        for profile in profiles where profile.archivedAt == nil {
            profile.setDefault(profile.id == id, at: date)
        }
        try context.save()
    }

    func setPrimaryPersonImage(id: UUID, for profileID: UUID, at date: Date = .now) throws {
        let images = try context.fetch(FetchDescriptor<PersonImage>())
        guard images.contains(where: { $0.id == id && $0.profile.id == profileID }) else {
            throw WardrobeRepositoryError.modelNotFound(model: "PersonImage", id: id)
        }
        for image in images where image.profile.id == profileID {
            image.setPrimary(image.id == id, at: date)
        }
        try context.save()
    }

    func deletePersonProfile(id: UUID) throws {
        guard let profile = try personProfile(id: id) else { return }
        context.delete(profile)
        try context.save()
    }

    func insert(_ outfit: Outfit) throws {
        try WardrobeDataRules.validateOutfit(outfit)
        context.insert(outfit)
    }

    func outfit(id: UUID) throws -> Outfit? {
        let descriptor = FetchDescriptor<Outfit>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func deleteOutfit(id: UUID) throws {
        guard let outfit = try outfit(id: id) else { return }
        context.delete(outfit)
        try context.save()
    }

    func insert(_ record: GenerationRecord) throws {
        try WardrobeDataRules.validateGeneration(record)
        context.insert(record)
    }

    func generationRecord(id: UUID) throws -> GenerationRecord? {
        let descriptor = FetchDescriptor<GenerationRecord>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func transitionGeneration(id: UUID, to status: GenerationStatus, at date: Date = .now) throws {
        guard let record = try generationRecord(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "GenerationRecord", id: id)
        }
        try WardrobeDataRules.validateTransition(from: record.statusCode, to: status)
        record.setStatus(status, at: date)
        try context.save()
    }

    func deleteGeneration(id: UUID) throws {
        guard let record = try generationRecord(id: id) else { return }
        context.delete(record)
        try context.save()
    }

    func save() throws { try context.save() }

}
