import Foundation
import SwiftData

// MARK: - Export

@MainActor
protocol BackupMetadataExporting: Sendable {
    func exportRecords() throws -> BackupRecordsV1
    func nonterminalGenerationCount() throws -> Int
}

@MainActor
final class SwiftDataBackupMetadataExporter: BackupMetadataExporting {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func exportRecords() throws -> BackupRecordsV1 {
        let clothing = try context.fetch(FetchDescriptor<ClothingItem>())
        let profiles = try context.fetch(FetchDescriptor<PersonProfile>())
        let images = try context.fetch(FetchDescriptor<PersonImage>())
        let outfits = try context.fetch(FetchDescriptor<Outfit>())
        let outfitItems = try context.fetch(FetchDescriptor<OutfitItem>())
        let generations = try context.fetch(FetchDescriptor<GenerationRecord>())
        let personInputs = try context.fetch(FetchDescriptor<GenerationPersonInput>())
        let garmentInputs = try context.fetch(FetchDescriptor<GenerationGarmentInput>())

        let records = BackupRecordsV1(
            clothingItems: clothing.map(Self.clothingRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            personProfiles: profiles.map(Self.profileRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            personImages: images.map(Self.imageRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            outfits: outfits.map(Self.outfitRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            outfitItems: outfitItems.map(Self.outfitItemRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            generations: generations.map(Self.generationRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            generationPersonInputs: personInputs.map(Self.personInputRecord).sorted { $0.id.uuidString < $1.id.uuidString },
            generationGarmentInputs: garmentInputs.map(Self.garmentInputRecord).sorted { $0.id.uuidString < $1.id.uuidString }
        )
        return records
    }

    func nonterminalGenerationCount() throws -> Int {
        try context.fetch(FetchDescriptor<GenerationRecord>()).filter {
            guard case let .known(status) = $0.resolvedStatus else { return false }
            return !status.isTerminal
        }.count
    }

    private static func clothingRecord(_ item: ClothingItem) -> BackupClothingRecordV1 {
        BackupClothingRecordV1(
            id: item.id,
            name: item.name,
            notes: item.notes,
            categoryCode: item.categoryCode,
            subcategoryCode: item.subcategoryCode,
            brand: item.brand,
            colorCodes: item.colorCodes,
            seasonCodes: item.seasonCodes,
            styleCodes: item.styleCodes,
            materials: item.materials,
            tags: item.tags,
            isFavorite: item.isFavorite,
            originalResourceID: item.originalResourceID,
            processedResourceID: item.processedResourceID,
            thumbnailResourceID: item.thumbnailResourceID,
            archivedAt: item.archivedAt,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }

    private static func profileRecord(_ profile: PersonProfile) -> BackupPersonProfileV1 {
        BackupPersonProfileV1(
            id: profile.id,
            name: profile.name,
            notes: profile.notes,
            isDefault: profile.isDefault,
            archivedAt: profile.archivedAt,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt
        )
    }

    private static func imageRecord(_ image: PersonImage) -> BackupPersonImageV1 {
        BackupPersonImageV1(
            id: image.id,
            profileID: image.profile.id,
            isPrimary: image.isPrimary,
            originalResourceID: image.originalResourceID,
            processedResourceID: image.processedResourceID,
            thumbnailResourceID: image.thumbnailResourceID,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            createdAt: image.createdAt,
            updatedAt: image.updatedAt
        )
    }

    private static func outfitRecord(_ outfit: Outfit) -> BackupOutfitV1 {
        BackupOutfitV1(
            id: outfit.id,
            name: outfit.name,
            notes: outfit.notes,
            isFavorite: outfit.isFavorite,
            coverResourceID: outfit.coverResourceID,
            archivedAt: outfit.archivedAt,
            createdAt: outfit.createdAt,
            updatedAt: outfit.updatedAt
        )
    }

    private static func outfitItemRecord(_ item: OutfitItem) -> BackupOutfitItemV1 {
        BackupOutfitItemV1(
            id: item.id,
            outfitID: item.outfit.id,
            clothingItemID: item.clothingItemID,
            clothingItemRelationID: item.clothingItem?.id,
            clothingNameSnapshot: item.clothingNameSnapshot,
            thumbnailResourceIDSnapshot: item.thumbnailResourceIDSnapshot,
            slotCode: item.slotCode,
            sortOrder: item.sortOrder,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }

    private static func generationRecord(_ record: GenerationRecord) -> BackupGenerationRecordV1 {
        BackupGenerationRecordV1(
            id: record.id,
            sourceGenerationID: record.sourceGenerationID,
            providerID: record.providerID,
            providerModelID: record.providerModelID,
            statusCode: record.statusCode,
            prompt: record.prompt,
            optionsJSON: record.optionsJSON,
            providerRequestID: record.providerRequestID,
            resultResourceID: record.resultResourceID,
            resultThumbnailResourceID: record.resultThumbnailResourceID,
            errorCode: record.errorCode,
            errorMessage: record.errorMessage,
            attemptCount: record.attemptCount,
            startedAt: record.startedAt,
            completedAt: record.completedAt,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private static func personInputRecord(_ input: GenerationPersonInput) -> BackupGenerationPersonInputV1 {
        BackupGenerationPersonInputV1(
            id: input.id,
            generationID: input.generation.id,
            personProfileID: input.personProfileID,
            personProfileRelationID: input.personProfile?.id,
            personNameSnapshot: input.personNameSnapshot,
            personImageID: input.personImageID,
            personImageRelationID: input.personImage?.id,
            resourceIDSnapshot: input.resourceIDSnapshot,
            sortOrder: input.sortOrder,
            createdAt: input.createdAt,
            updatedAt: input.updatedAt
        )
    }

    private static func garmentInputRecord(_ input: GenerationGarmentInput) -> BackupGenerationGarmentInputV1 {
        BackupGenerationGarmentInputV1(
            id: input.id,
            generationID: input.generation.id,
            clothingItemID: input.clothingItemID,
            clothingItemRelationID: input.clothingItem?.id,
            clothingNameSnapshot: input.clothingNameSnapshot,
            categoryCodeSnapshot: input.categoryCodeSnapshot,
            slotCode: input.slotCode,
            resourceIDSnapshot: input.resourceIDSnapshot,
            sortOrder: input.sortOrder,
            createdAt: input.createdAt,
            updatedAt: input.updatedAt
        )
    }
}

// MARK: - Import

@MainActor
final class BackupMetadataImporter {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// Builds the full object graph in dependency order and saves once.
    /// Unknown raw codes and nullified current relations are preserved exactly
    /// as recorded; no automatic re-linking is performed.
    func importRecords(_ records: BackupRecordsV1) throws -> BackupRecordCounts {
        var clothingByID: [UUID: ClothingItem] = [:]
        for record in records.clothingItems {
            let item = ClothingItem(
                id: record.id,
                name: record.name,
                notes: record.notes,
                categoryCode: record.categoryCode,
                subcategoryCode: record.subcategoryCode,
                brand: record.brand,
                colorCodes: record.colorCodes,
                seasonCodes: record.seasonCodes,
                styleCodes: record.styleCodes,
                materials: record.materials,
                tags: record.tags,
                isFavorite: record.isFavorite,
                originalResourceID: record.originalResourceID,
                processedResourceID: record.processedResourceID,
                thumbnailResourceID: record.thumbnailResourceID,
                archivedAt: record.archivedAt,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            context.insert(item)
            clothingByID[record.id] = item
        }

        var profilesByID: [UUID: PersonProfile] = [:]
        for record in records.personProfiles {
            let profile = PersonProfile(
                id: record.id,
                name: record.name,
                notes: record.notes,
                isDefault: record.isDefault,
                archivedAt: record.archivedAt,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            context.insert(profile)
            profilesByID[record.id] = profile
        }

        var imagesByID: [UUID: PersonImage] = [:]
        for record in records.personImages {
            guard let profile = profilesByID[record.profileID] else {
                throw BackupError.brokenRelationship(entity: "PersonImage", id: record.id)
            }
            let image = PersonImage(
                id: record.id,
                profile: profile,
                isPrimary: record.isPrimary,
                originalResourceID: record.originalResourceID,
                processedResourceID: record.processedResourceID,
                thumbnailResourceID: record.thumbnailResourceID,
                pixelWidth: record.pixelWidth,
                pixelHeight: record.pixelHeight,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            context.insert(image)
            imagesByID[record.id] = image
        }

        var outfitsByID: [UUID: Outfit] = [:]
        for record in records.outfits {
            let outfit = Outfit(
                id: record.id,
                name: record.name,
                notes: record.notes,
                isFavorite: record.isFavorite,
                coverResourceID: record.coverResourceID,
                archivedAt: record.archivedAt,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            context.insert(outfit)
            outfitsByID[record.id] = outfit
        }

        for record in records.outfitItems {
            guard let outfit = outfitsByID[record.outfitID] else {
                throw BackupError.brokenRelationship(entity: "OutfitItem", id: record.id)
            }
            let item = OutfitItem(
                id: record.id,
                outfit: outfit,
                clothingItem: record.clothingItemRelationID.flatMap { clothingByID[$0] },
                clothingItemID: record.clothingItemID,
                clothingNameSnapshot: record.clothingNameSnapshot,
                thumbnailResourceIDSnapshot: record.thumbnailResourceIDSnapshot,
                slotCode: record.slotCode,
                sortOrder: record.sortOrder,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            context.insert(item)
        }

        var generationsByID: [UUID: GenerationRecord] = [:]
        for record in records.generations {
            let generation = GenerationRecord(
                id: record.id,
                sourceGenerationID: record.sourceGenerationID,
                providerID: record.providerID,
                providerModelID: record.providerModelID,
                statusCode: record.statusCode,
                prompt: record.prompt,
                optionsJSON: record.optionsJSON,
                providerRequestID: record.providerRequestID,
                resultResourceID: record.resultResourceID,
                resultThumbnailResourceID: record.resultThumbnailResourceID,
                errorCode: record.errorCode,
                errorMessage: record.errorMessage,
                attemptCount: record.attemptCount,
                startedAt: record.startedAt,
                completedAt: record.completedAt,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            context.insert(generation)
            generationsByID[record.id] = generation
        }

        for record in records.generationPersonInputs {
            guard let generation = generationsByID[record.generationID] else {
                throw BackupError.brokenRelationship(entity: "GenerationPersonInput", id: record.id)
            }
            let input = GenerationPersonInput(
                id: record.id,
                generation: generation,
                personProfile: record.personProfileRelationID.flatMap { profilesByID[$0] },
                personProfileID: record.personProfileID,
                personNameSnapshot: record.personNameSnapshot,
                personImage: record.personImageRelationID.flatMap { imagesByID[$0] },
                personImageID: record.personImageID,
                resourceIDSnapshot: record.resourceIDSnapshot,
                sortOrder: record.sortOrder,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            context.insert(input)
        }

        for record in records.generationGarmentInputs {
            guard let generation = generationsByID[record.generationID] else {
                throw BackupError.brokenRelationship(entity: "GenerationGarmentInput", id: record.id)
            }
            let input = GenerationGarmentInput(
                id: record.id,
                generation: generation,
                clothingItem: record.clothingItemRelationID.flatMap { clothingByID[$0] },
                clothingItemID: record.clothingItemID,
                clothingNameSnapshot: record.clothingNameSnapshot,
                categoryCodeSnapshot: record.categoryCodeSnapshot,
                slotCode: record.slotCode,
                resourceIDSnapshot: record.resourceIDSnapshot,
                sortOrder: record.sortOrder,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
            context.insert(input)
        }

        try context.save()
        return BackupRecordCounts(records: records)
    }
}
