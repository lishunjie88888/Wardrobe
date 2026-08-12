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

    func outfits(matching query: OutfitQuery) throws -> [OutfitRecord] {
        let needle = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = try context.fetch(FetchDescriptor<Outfit>()).filter { outfit in
            switch query.archive {
            case .active where outfit.archivedAt != nil: return false
            case .archived where outfit.archivedAt == nil: return false
            default: break
            }
            if query.favoritesOnly && !outfit.isFavorite { return false }
            guard !needle.isEmpty else { return true }
            return outfit.name.localizedCaseInsensitiveContains(needle) ||
                (outfit.notes?.localizedCaseInsensitiveContains(needle) == true) ||
                outfit.items.contains {
                    ($0.clothingItem?.name.localizedCaseInsensitiveContains(needle) == true) ||
                    $0.clothingNameSnapshot.localizedCaseInsensitiveContains(needle)
                }
        }
        let sorted = filtered.sorted { left, right in
            switch query.sort {
            case .recentlyUpdated:
                return left.updatedAt == right.updatedAt ? left.id.uuidString < right.id.uuidString : left.updatedAt > right.updatedAt
            case .newest:
                return left.createdAt == right.createdAt ? left.id.uuidString < right.id.uuidString : left.createdAt > right.createdAt
            case .name:
                let comparison = left.name.localizedStandardCompare(right.name)
                return comparison == .orderedSame ? left.id.uuidString < right.id.uuidString : comparison == .orderedAscending
            case .favoritesFirst:
                if left.isFavorite != right.isFavorite { return left.isFavorite }
                return left.updatedAt == right.updatedAt ? left.id.uuidString < right.id.uuidString : left.updatedAt > right.updatedAt
            }
        }
        return sorted.prefix(max(1, query.fetchLimit)).map(Self.outfitRecord)
    }

    func outfitRecord(id: UUID) throws -> OutfitRecord? {
        try outfit(id: id).map(Self.outfitRecord)
    }

    func createOutfit(draft: OutfitDraft, items: [OutfitCreationItem], at date: Date) throws -> OutfitRecord {
        let normalized = draft.normalized()
        guard !items.isEmpty else { throw OutfitServiceError.emptyOutfit }
        let outfit = Outfit(name: normalized.name, notes: normalized.notes, isFavorite: normalized.isFavorite, createdAt: date)
        var persistedItems: [OutfitItem] = []
        for input in items {
            guard let clothing = try clothingItem(id: input.clothingItemID), clothing.archivedAt == nil else {
                throw OutfitServiceError.clothingUnavailable(input.clothingItemID)
            }
            let snapshotName = clothing.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !snapshotName.isEmpty else { throw OutfitServiceError.invalidSnapshotName(input.clothingItemID) }
            persistedItems.append(OutfitItem(
                outfit: outfit,
                clothingItem: clothing,
                clothingItemID: clothing.id,
                clothingNameSnapshot: snapshotName,
                thumbnailResourceIDSnapshot: clothing.thumbnailResourceID,
                slotCode: input.slotCode,
                sortOrder: input.sortOrder,
                createdAt: date
            ))
        }
        outfit.items = persistedItems
        try WardrobeDataRules.validateOutfit(outfit)
        context.insert(outfit)
        do {
            try context.save()
            return Self.outfitRecord(outfit)
        } catch {
            context.rollback()
            throw error
        }
    }

    func updateOutfit(id: UUID, draft: OutfitDraft, at date: Date) throws -> OutfitRecord {
        guard let outfit = try outfit(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "Outfit", id: id)
        }
        let normalized = draft.normalized()
        outfit.name = normalized.name
        outfit.notes = normalized.notes
        outfit.isFavorite = normalized.isFavorite
        outfit.markUpdated(at: date)
        try context.save()
        return Self.outfitRecord(outfit)
    }

    func setOutfitFavorite(id: UUID, isFavorite: Bool, at date: Date) throws -> OutfitRecord {
        guard let outfit = try outfit(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "Outfit", id: id)
        }
        outfit.isFavorite = isFavorite
        outfit.markUpdated(at: date)
        try context.save()
        return Self.outfitRecord(outfit)
    }

    func setOutfitArchived(id: UUID, archived: Bool, at date: Date) throws -> OutfitRecord {
        guard let outfit = try outfit(id: id) else {
            throw WardrobeRepositoryError.modelNotFound(model: "Outfit", id: id)
        }
        outfit.archivedAt = archived ? date : nil
        outfit.markUpdated(at: date)
        try context.save()
        return Self.outfitRecord(outfit)
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

    func allGenerationRecords() throws -> [GenerationRecord] {
        try context.fetch(FetchDescriptor<GenerationRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func nonterminalGenerationRecords() throws -> [GenerationRecord] {
        try context.fetch(FetchDescriptor<GenerationRecord>()).filter {
            guard case let .known(status) = $0.resolvedStatus else { return false }
            return !status.isTerminal
        }
    }

    func generationHistory(matching query: GenerationHistoryQuery) throws -> [GenerationHistoryRecord] {
        let records = try context.fetch(FetchDescriptor<GenerationRecord>()).filter { record in
            if let providerID = query.providerID, record.providerID != providerID { return false }
            switch query.status {
            case .all: return true
            case .succeeded: return record.statusCode == GenerationStatus.succeeded.rawValue
            case .failed: return record.statusCode == GenerationStatus.failed.rawValue
            case .cancelled: return record.statusCode == GenerationStatus.cancelled.rawValue
            case .inProgress:
                return [GenerationStatus.queued, .preparing, .running].map(\.rawValue).contains(record.statusCode)
            }
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        return records.prefix(max(1, query.fetchLimit)).map(Self.generationHistoryRecord)
    }

    func generationDetail(id: UUID) throws -> GenerationDetailRecord? {
        guard let record = try generationRecord(id: id) else { return nil }
        let sourceExists = try record.sourceGenerationID.map { try generationRecord(id: $0) != nil } ?? false
        var persons: [GenerationPersonSnapshotRecord] = []
        for input in record.personInputs {
            let resource = try? StorageResourceID(rawValue: input.resourceIDSnapshot)
            let profileExists = input.personProfile != nil
            let profileActive = input.personProfile.map { $0.archivedAt == nil } ?? false
            persons.append(GenerationPersonSnapshotRecord(
                id: input.id,
                personProfileID: input.personProfileID,
                personImageID: input.personImageID,
                personNameSnapshot: input.personNameSnapshot,
                resourceIDSnapshot: resource,
                sortOrder: input.sortOrder,
                hasCurrentProfile: profileExists,
                currentProfileIsActive: profileActive,
                hasCurrentImage: input.personImage != nil
            ))
        }
        persons.sort {
            $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder
        }
        var garments: [GenerationGarmentSnapshotRecord] = []
        for input in record.garmentInputs {
            let resource = try? StorageResourceID(rawValue: input.resourceIDSnapshot)
            let clothingExists = input.clothingItem != nil
            let clothingActive = input.clothingItem.map { $0.archivedAt == nil } ?? false
            garments.append(GenerationGarmentSnapshotRecord(
                id: input.id,
                clothingItemID: input.clothingItemID,
                clothingNameSnapshot: input.clothingNameSnapshot,
                categoryCodeSnapshot: input.categoryCodeSnapshot,
                slotCode: input.slotCode,
                resourceIDSnapshot: resource,
                sortOrder: input.sortOrder,
                hasCurrentClothing: clothingExists,
                currentClothingIsActive: clothingActive,
                currentClothingName: input.clothingItem?.name,
                currentCategoryCode: input.clothingItem?.categoryCode
            ))
        }
        garments.sort(by: Self.generationGarmentOrder)
        return GenerationDetailRecord(
            id: record.id,
            sourceGenerationID: record.sourceGenerationID,
            sourceExists: sourceExists,
            providerID: record.providerID,
            providerModelID: record.providerModelID,
            status: Self.generationStatus(record),
            prompt: record.prompt,
            optionsText: GenerationHistoryRedactor.options(record.optionsJSON),
            providerRequestID: record.providerRequestID,
            resultResourceID: record.resultResourceID.flatMap { try? StorageResourceID(rawValue: $0) },
            resultThumbnailResourceID: record.resultThumbnailResourceID.flatMap { try? StorageResourceID(rawValue: $0) },
            errorCode: record.errorCode,
            safeErrorMessage: GenerationHistoryRedactor.errorMessage(record.errorMessage),
            attemptCount: record.attemptCount,
            startedAt: record.startedAt,
            completedAt: record.completedAt,
            createdAt: record.createdAt,
            persons: persons,
            garments: garments
        )
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

    private static func outfitRecord(_ outfit: Outfit) -> OutfitRecord {
        let items = outfit.items.map { item in
            OutfitItemRecord(
                id: item.id,
                clothingItemID: item.clothingItemID,
                hasCurrentClothing: item.clothingItem != nil,
                currentClothingIsActive: item.clothingItem?.archivedAt == nil,
                currentClothingName: item.clothingItem?.name,
                currentThumbnailResourceID: item.clothingItem?.thumbnailResourceID.flatMap { try? StorageResourceID(rawValue: $0) },
                currentCategoryCode: item.clothingItem?.categoryCode,
                clothingNameSnapshot: item.clothingNameSnapshot,
                thumbnailResourceIDSnapshot: item.thumbnailResourceIDSnapshot.flatMap { try? StorageResourceID(rawValue: $0) },
                slotCode: item.slotCode,
                sortOrder: item.sortOrder,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt
            )
        }.sorted { left, right in
            let leftIndex = TryOnSlot.allCases.firstIndex { $0.rawValue == left.slotCode } ?? Int.max
            let rightIndex = TryOnSlot.allCases.firstIndex { $0.rawValue == right.slotCode } ?? Int.max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            if left.sortOrder != right.sortOrder { return left.sortOrder < right.sortOrder }
            return left.id.uuidString < right.id.uuidString
        }
        return OutfitRecord(
            id: outfit.id,
            draft: OutfitDraft(name: outfit.name, notes: outfit.notes, isFavorite: outfit.isFavorite),
            coverResourceID: outfit.coverResourceID.flatMap { try? StorageResourceID(rawValue: $0) },
            archivedAt: outfit.archivedAt,
            createdAt: outfit.createdAt,
            updatedAt: outfit.updatedAt,
            items: items
        )
    }

    private static func generationHistoryRecord(_ record: GenerationRecord) -> GenerationHistoryRecord {
        let persons = record.personInputs.sorted {
            $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder
        }
        let garments = record.garmentInputs.sorted(by: { left, right in
            generationGarmentOrder(
                GenerationGarmentSnapshotRecord(id: left.id, clothingItemID: left.clothingItemID, clothingNameSnapshot: left.clothingNameSnapshot, categoryCodeSnapshot: left.categoryCodeSnapshot, slotCode: left.slotCode, resourceIDSnapshot: nil, sortOrder: left.sortOrder, hasCurrentClothing: false, currentClothingIsActive: false, currentClothingName: nil, currentCategoryCode: nil),
                GenerationGarmentSnapshotRecord(id: right.id, clothingItemID: right.clothingItemID, clothingNameSnapshot: right.clothingNameSnapshot, categoryCodeSnapshot: right.categoryCodeSnapshot, slotCode: right.slotCode, resourceIDSnapshot: nil, sortOrder: right.sortOrder, hasCurrentClothing: false, currentClothingIsActive: false, currentClothingName: nil, currentCategoryCode: nil)
            )
        })
        return GenerationHistoryRecord(
            id: record.id,
            providerID: record.providerID,
            status: generationStatus(record),
            thumbnailResourceID: record.resultThumbnailResourceID.flatMap { try? StorageResourceID(rawValue: $0) },
            personNameSnapshot: persons.first?.personNameSnapshot ?? "未知人物",
            garmentSummary: garments.map(\.clothingNameSnapshot).joined(separator: "、"),
            createdAt: record.createdAt,
            completedAt: record.completedAt
        )
    }

    private static func generationStatus(_ record: GenerationRecord) -> GenerationDisplayStatus {
        if record.statusCode == GenerationStatus.failed.rawValue, record.errorCode == "interrupted" { return .interrupted }
        if let status = GenerationStatus(rawValue: record.statusCode) { return .known(status) }
        return .unknown(record.statusCode)
    }

    private static func generationGarmentOrder(_ left: GenerationGarmentSnapshotRecord, _ right: GenerationGarmentSnapshotRecord) -> Bool {
        let leftIndex = TryOnSlot.allCases.firstIndex { $0.rawValue == left.slotCode } ?? Int.max
        let rightIndex = TryOnSlot.allCases.firstIndex { $0.rawValue == right.slotCode } ?? Int.max
        if leftIndex != rightIndex { return leftIndex < rightIndex }
        if left.sortOrder != right.sortOrder { return left.sortOrder < right.sortOrder }
        return left.id.uuidString < right.id.uuidString
    }

}
