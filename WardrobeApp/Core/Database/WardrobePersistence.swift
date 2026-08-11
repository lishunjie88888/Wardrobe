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

    func clothingItems(matching query: ClothingQuery) throws -> [ClothingRecord] {
        let items = try context.fetch(FetchDescriptor<ClothingItem>())
        let needle = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter { item in
            switch query.archive {
            case .active where item.archivedAt != nil: return false
            case .archived where item.archivedAt == nil: return false
            default: break
            }
            if query.favoritesOnly && !item.isFavorite { return false }
            if let code = query.categoryCode, item.categoryCode != code { return false }
            if let code = query.seasonCode, !item.seasonCodes.contains(code) { return false }
            if let code = query.colorCode, !item.colorCodes.contains(code) { return false }
            if let code = query.styleCode, !item.styleCodes.contains(code) { return false }
            guard !needle.isEmpty else { return true }
            let searchable = [item.name, item.brand ?? ""] + item.colorCodes + item.materials + item.tags
            return searchable.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        let sorted = filtered.sorted { left, right in
            switch query.sort {
            case .newest:
                return left.createdAt == right.createdAt ? left.id.uuidString < right.id.uuidString : left.createdAt > right.createdAt
            case .recentlyUpdated:
                return left.updatedAt == right.updatedAt ? left.id.uuidString < right.id.uuidString : left.updatedAt > right.updatedAt
            case .name:
                let result = left.name.localizedStandardCompare(right.name)
                return result == .orderedSame ? left.id.uuidString < right.id.uuidString : result == .orderedAscending
            case .favoritesFirst:
                if left.isFavorite != right.isFavorite { return left.isFavorite }
                return left.createdAt == right.createdAt ? left.id.uuidString < right.id.uuidString : left.createdAt > right.createdAt
            }
        }
        return try sorted.prefix(max(1, query.fetchLimit)).map(Self.record)
    }

    func insertAndSave(_ item: ClothingItem) throws {
        context.insert(item)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func updateClothing(id: UUID, draft: ClothingDraft, at date: Date) throws -> ClothingRecord {
        guard let item = try clothingItem(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "ClothingItem", id: id)
        }
        let normalized = try draft.normalized()
        item.name = normalized.name
        item.notes = normalized.notes
        item.categoryCode = normalized.categoryCode
        item.subcategoryCode = normalized.subcategoryCode
        item.brand = normalized.brand
        item.colorCodes = normalized.colorCodes
        item.seasonCodes = normalized.seasonCodes
        item.styleCodes = normalized.styleCodes
        item.materials = normalized.materials
        item.tags = normalized.tags
        item.isFavorite = normalized.isFavorite
        item.markUpdated(at: date)
        try context.save()
        return try Self.record(item)
    }

    func setClothingFavorite(id: UUID, isFavorite: Bool, at date: Date) throws -> ClothingRecord {
        guard let item = try clothingItem(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "ClothingItem", id: id)
        }
        item.isFavorite = isFavorite
        item.markUpdated(at: date)
        try context.save()
        return try Self.record(item)
    }

    func setClothingArchived(id: UUID, archived: Bool, at date: Date) throws -> ClothingRecord {
        guard let item = try clothingItem(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "ClothingItem", id: id)
        }
        item.archivedAt = archived ? date : nil
        item.markUpdated(at: date)
        try context.save()
        return try Self.record(item)
    }

    func clothingDeleteImpact(id: UUID) throws -> ClothingDeleteImpact {
        let outfits = try context.fetch(FetchDescriptor<OutfitItem>()).filter { $0.clothingItemID == id }.count
        let generations = try context.fetch(FetchDescriptor<GenerationGarmentInput>()).filter { $0.clothingItemID == id }.count
        return ClothingDeleteImpact(clothingID: id, outfitSnapshotCount: outfits, generationSnapshotCount: generations)
    }

    func allPersistedResourceIDStrings() throws -> Set<String> {
        var result = Set<String>()
        for item in try context.fetch(FetchDescriptor<ClothingItem>()) {
            result.insert(item.originalResourceID)
            if let value = item.processedResourceID { result.insert(value) }
            if let value = item.thumbnailResourceID { result.insert(value) }
        }
        for image in try context.fetch(FetchDescriptor<PersonImage>()) {
            result.insert(image.originalResourceID)
            if let value = image.processedResourceID { result.insert(value) }
            if let value = image.thumbnailResourceID { result.insert(value) }
        }
        for outfit in try context.fetch(FetchDescriptor<Outfit>()) {
            if let value = outfit.coverResourceID { result.insert(value) }
        }
        for item in try context.fetch(FetchDescriptor<OutfitItem>()) {
            if let value = item.thumbnailResourceIDSnapshot { result.insert(value) }
        }
        for generation in try context.fetch(FetchDescriptor<GenerationRecord>()) {
            if let value = generation.resultResourceID { result.insert(value) }
            if let value = generation.resultThumbnailResourceID { result.insert(value) }
        }
        for input in try context.fetch(FetchDescriptor<GenerationPersonInput>()) {
            result.insert(input.resourceIDSnapshot)
        }
        for input in try context.fetch(FetchDescriptor<GenerationGarmentInput>()) {
            result.insert(input.resourceIDSnapshot)
        }
        return result
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

    func personProfiles(archive: PersonArchiveFilter) throws -> [PersonProfileRecord] {
        let profiles = try context.fetch(FetchDescriptor<PersonProfile>())
            .filter { profile in
                switch archive {
                case .active: profile.archivedAt == nil
                case .archived: profile.archivedAt != nil
                case .all: true
                }
            }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        return try profiles.map(Self.personRecord)
    }

    func createPersonProfile(draft: PersonDraft, at date: Date) throws -> PersonProfileRecord {
        let normalized = try draft.normalized()
        let profile = PersonProfile(name: normalized.name, notes: normalized.notes, createdAt: date)
        context.insert(profile)
        do {
            try context.save()
            return try Self.personRecord(profile)
        } catch {
            context.rollback()
            throw error
        }
    }

    func updatePersonProfile(id: UUID, draft: PersonDraft, at date: Date) throws -> PersonProfileRecord {
        guard let profile = try personProfile(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "PersonProfile", id: id)
        }
        let normalized = try draft.normalized()
        profile.name = normalized.name
        profile.notes = normalized.notes
        profile.markUpdated(at: date)
        try context.save()
        return try Self.personRecord(profile)
    }

    func setPersonProfileArchived(id: UUID, archived: Bool, at date: Date) throws -> PersonProfileRecord {
        guard let profile = try personProfile(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "PersonProfile", id: id)
        }
        profile.archivedAt = archived ? date : nil
        if archived, profile.isDefault { profile.setDefault(false, at: date) }
        profile.markUpdated(at: date)
        try context.save()
        return try Self.personRecord(profile)
    }

    func insertPersonImageAndSave(_ image: PersonImage, at date: Date) throws -> PersonImageRecord {
        if image.isPrimary {
            for sibling in image.profile.images where sibling.id != image.id {
                sibling.setPrimary(false, at: date)
            }
        }
        context.insert(image)
        do {
            try context.save()
            return try Self.personImageRecord(image)
        } catch {
            context.rollback()
            throw error
        }
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

    func defaultPersonReferenceSet() throws -> PersonReferenceSet? {
        let profiles = try context.fetch(FetchDescriptor<PersonProfile>())
        guard let profile = profiles.first(where: { $0.archivedAt == nil && $0.isDefault }) else { return nil }
        return try Self.referenceSet(for: profile)
    }

    func personReferenceSet(profileID: UUID) throws -> PersonReferenceSet? {
        guard let profile = try personProfile(id: profileID), profile.archivedAt == nil else { return nil }
        return try Self.referenceSet(for: profile)
    }

    private static func referenceSet(for profile: PersonProfile) throws -> PersonReferenceSet {
        let images = try profile.images.map(Self.personImageRecord).sorted(by: Self.personImageOrder)
        let primary = images.first(where: \.isPrimary)
        return PersonReferenceSet(
            profileID: profile.id,
            primaryImage: primary,
            additionalImages: images.filter { $0.id != primary?.id }
        )
    }

    func personImageDeleteImpact(id: UUID) throws -> PersonImageDeleteImpact {
        let count = try context.fetch(FetchDescriptor<GenerationPersonInput>()).filter { $0.personImageID == id }.count
        return PersonImageDeleteImpact(imageID: id, generationSnapshotCount: count)
    }

    func personProfileDeleteImpact(id: UUID) throws -> PersonProfileDeleteImpact {
        guard let profile = try personProfile(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "PersonProfile", id: id)
        }
        let inputs = try context.fetch(FetchDescriptor<GenerationPersonInput>())
        let imageIDs = Set(profile.images.map(\.id))
        return PersonProfileDeleteImpact(
            profileID: id,
            imageCount: profile.images.count,
            generationProfileSnapshotCount: inputs.filter { $0.personProfileID == id }.count,
            generationImageSnapshotCount: inputs.filter { imageIDs.contains($0.personImageID) }.count
        )
    }

    func deletePersonImage(id: UUID, at date: Date) throws {
        guard let image = try personImage(id: id) else { return }
        let profile = image.profile
        let wasPrimary = image.isPrimary
        context.delete(image)
        if wasPrimary {
            let remaining = profile.images.filter { $0.id != id }.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            remaining.first?.setPrimary(true, at: date)
        }
        profile.markUpdated(at: date)
        try context.save()
    }

    func deletePersonProfileAndSave(id: UUID) throws {
        guard let profile = try personProfile(id: id) else { return }
        context.delete(profile)
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

    private static func record(_ item: ClothingItem) throws -> ClothingRecord {
        ClothingRecord(
            id: item.id,
            draft: ClothingDraft(
                name: item.name,
                categoryCode: item.categoryCode,
                subcategoryCode: item.subcategoryCode,
                brand: item.brand,
                colorCodes: item.colorCodes,
                seasonCodes: item.seasonCodes,
                styleCodes: item.styleCodes,
                materials: item.materials,
                tags: item.tags,
                isFavorite: item.isFavorite,
                notes: item.notes
            ),
            originalResourceID: try StorageResourceID(rawValue: item.originalResourceID),
            processedResourceID: try item.processedResourceID.map(StorageResourceID.init(rawValue:)),
            thumbnailResourceID: try item.thumbnailResourceID.map(StorageResourceID.init(rawValue:)),
            archivedAt: item.archivedAt,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }

    private static func personRecord(_ profile: PersonProfile) throws -> PersonProfileRecord {
        let images = try profile.images.map(personImageRecord).sorted(by: personImageOrder)
        return PersonProfileRecord(
            id: profile.id,
            draft: PersonDraft(name: profile.name, notes: profile.notes),
            isDefault: profile.isDefault,
            archivedAt: profile.archivedAt,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt,
            images: images
        )
    }

    private static func personImageRecord(_ image: PersonImage) throws -> PersonImageRecord {
        PersonImageRecord(
            id: image.id,
            profileID: image.profile.id,
            isPrimary: image.isPrimary,
            originalResourceID: try StorageResourceID(rawValue: image.originalResourceID),
            processedResourceID: try image.processedResourceID.map(StorageResourceID.init(rawValue:)),
            thumbnailResourceID: try image.thumbnailResourceID.map(StorageResourceID.init(rawValue:)),
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            createdAt: image.createdAt,
            updatedAt: image.updatedAt
        )
    }

    private static func personImageOrder(_ left: PersonImageRecord, _ right: PersonImageRecord) -> Bool {
        if left.isPrimary != right.isPrimary { return left.isPrimary }
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        return left.id.uuidString < right.id.uuidString
    }

}
