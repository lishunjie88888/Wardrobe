import Foundation
import SwiftData

enum WardrobeSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            ClothingItem.self,
            PersonProfile.self,
            PersonImage.self,
            Outfit.self,
            OutfitItem.self,
            GenerationRecord.self,
            GenerationPersonInput.self,
            GenerationGarmentInput.self,
        ]
    }

    @Model
    final class ClothingItem {
        @Attribute(.unique) private(set) var id: UUID
        var name: String
        var notes: String?
        var categoryCode: String
        var subcategoryCode: String?
        var brand: String?
        var colorCodes: [String]
        var seasonCodes: [String]
        var styleCodes: [String]
        var materials: [String]
        var tags: [String]
        var isFavorite: Bool
        var originalResourceID: String
        var processedResourceID: String?
        var thumbnailResourceID: String?
        var archivedAt: Date?
        private(set) var createdAt: Date
        private(set) var updatedAt: Date

        @Relationship(deleteRule: .nullify, inverse: \OutfitItem.clothingItem)
        var outfitItems: [OutfitItem]
        @Relationship(deleteRule: .nullify, inverse: \GenerationGarmentInput.clothingItem)
        var generationInputs: [GenerationGarmentInput]

        init(
            id: UUID = UUID(),
            name: String = "",
            notes: String? = nil,
            categoryCode: String = ClothingCategory.other.rawValue,
            subcategoryCode: String? = nil,
            brand: String? = nil,
            colorCodes: [String] = [],
            seasonCodes: [String] = [],
            styleCodes: [String] = [],
            materials: [String] = [],
            tags: [String] = [],
            isFavorite: Bool = false,
            originalResourceID: String,
            processedResourceID: String? = nil,
            thumbnailResourceID: String? = nil,
            archivedAt: Date? = nil,
            createdAt: Date = .now,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.notes = notes
            self.categoryCode = categoryCode
            self.subcategoryCode = subcategoryCode
            self.brand = brand
            self.colorCodes = colorCodes
            self.seasonCodes = seasonCodes
            self.styleCodes = styleCodes
            self.materials = materials
            self.tags = tags
            self.isFavorite = isFavorite
            self.originalResourceID = originalResourceID
            self.processedResourceID = processedResourceID
            self.thumbnailResourceID = thumbnailResourceID
            self.archivedAt = archivedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.outfitItems = []
            self.generationInputs = []
        }

        var resolvedCategory: ResolvedCode<ClothingCategory> { ResolvedCode(categoryCode) }

        func markUpdated(at date: Date = .now) { updatedAt = date }
    }

    @Model
    final class PersonProfile {
        @Attribute(.unique) private(set) var id: UUID
        var name: String
        var notes: String?
        private(set) var isDefault: Bool
        var archivedAt: Date?
        private(set) var createdAt: Date
        private(set) var updatedAt: Date

        @Relationship(deleteRule: .cascade, inverse: \PersonImage.profile)
        var images: [PersonImage]
        @Relationship(deleteRule: .nullify, inverse: \GenerationPersonInput.personProfile)
        var generationInputs: [GenerationPersonInput]

        init(
            id: UUID = UUID(),
            name: String = "我",
            notes: String? = nil,
            isDefault: Bool = false,
            archivedAt: Date? = nil,
            createdAt: Date = .now,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.notes = notes
            self.isDefault = isDefault
            self.archivedAt = archivedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.images = []
            self.generationInputs = []
        }

        func setDefault(_ value: Bool, at date: Date = .now) {
            isDefault = value
            updatedAt = date
        }

        func markUpdated(at date: Date = .now) { updatedAt = date }
    }

    @Model
    final class PersonImage {
        @Attribute(.unique) private(set) var id: UUID
        var profile: PersonProfile
        private(set) var isPrimary: Bool
        var originalResourceID: String
        var processedResourceID: String?
        var thumbnailResourceID: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        private(set) var createdAt: Date
        private(set) var updatedAt: Date

        @Relationship(deleteRule: .nullify, inverse: \GenerationPersonInput.personImage)
        var generationInputs: [GenerationPersonInput]

        init(
            id: UUID = UUID(),
            profile: PersonProfile,
            isPrimary: Bool = false,
            originalResourceID: String,
            processedResourceID: String? = nil,
            thumbnailResourceID: String? = nil,
            pixelWidth: Int? = nil,
            pixelHeight: Int? = nil,
            createdAt: Date = .now,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.profile = profile
            self.isPrimary = isPrimary
            self.originalResourceID = originalResourceID
            self.processedResourceID = processedResourceID
            self.thumbnailResourceID = thumbnailResourceID
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.generationInputs = []
        }

        func setPrimary(_ value: Bool, at date: Date = .now) {
            isPrimary = value
            updatedAt = date
        }

        func markUpdated(at date: Date = .now) { updatedAt = date }
    }

    @Model
    final class Outfit {
        @Attribute(.unique) private(set) var id: UUID
        var name: String
        var notes: String?
        var isFavorite: Bool
        var coverResourceID: String?
        var archivedAt: Date?
        private(set) var createdAt: Date
        private(set) var updatedAt: Date

        @Relationship(deleteRule: .cascade, inverse: \OutfitItem.outfit)
        var items: [OutfitItem]

        init(
            id: UUID = UUID(),
            name: String = "未命名穿搭",
            notes: String? = nil,
            isFavorite: Bool = false,
            coverResourceID: String? = nil,
            archivedAt: Date? = nil,
            createdAt: Date = .now,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.notes = notes
            self.isFavorite = isFavorite
            self.coverResourceID = coverResourceID
            self.archivedAt = archivedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.items = []
        }

        func markUpdated(at date: Date = .now) { updatedAt = date }
    }

    @Model
    final class OutfitItem {
        @Attribute(.unique) private(set) var id: UUID
        var outfit: Outfit
        var clothingItem: ClothingItem?
        private(set) var clothingItemID: UUID
        var clothingNameSnapshot: String
        var thumbnailResourceIDSnapshot: String?
        var slotCode: String
        var sortOrder: Int
        private(set) var createdAt: Date
        private(set) var updatedAt: Date

        init(
            id: UUID = UUID(),
            outfit: Outfit,
            clothingItem: ClothingItem?,
            clothingItemID: UUID,
            clothingNameSnapshot: String = "",
            thumbnailResourceIDSnapshot: String? = nil,
            slotCode: String,
            sortOrder: Int = 0,
            createdAt: Date = .now,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.outfit = outfit
            self.clothingItem = clothingItem
            self.clothingItemID = clothingItemID
            self.clothingNameSnapshot = clothingNameSnapshot
            self.thumbnailResourceIDSnapshot = thumbnailResourceIDSnapshot
            self.slotCode = slotCode
            self.sortOrder = sortOrder
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
        }

        var resolvedSlot: ResolvedCode<TryOnSlot> { ResolvedCode(slotCode) }

        func markUpdated(at date: Date = .now) { updatedAt = date }
    }

    @Model
    final class GenerationRecord {
        @Attribute(.unique) private(set) var id: UUID
        var sourceGenerationID: UUID?
        var providerID: String
        var providerModelID: String?
        private(set) var statusCode: String
        var prompt: String
        var optionsJSON: String
        var providerRequestID: String?
        var resultResourceID: String?
        var resultThumbnailResourceID: String?
        var errorCode: String?
        var errorMessage: String?
        var attemptCount: Int
        var startedAt: Date?
        var completedAt: Date?
        private(set) var createdAt: Date
        private(set) var updatedAt: Date

        @Relationship(deleteRule: .cascade, inverse: \GenerationPersonInput.generation)
        var personInputs: [GenerationPersonInput]
        @Relationship(deleteRule: .cascade, inverse: \GenerationGarmentInput.generation)
        var garmentInputs: [GenerationGarmentInput]

        init(
            id: UUID = UUID(),
            sourceGenerationID: UUID? = nil,
            providerID: String,
            providerModelID: String? = nil,
            statusCode: String = GenerationStatus.queued.rawValue,
            prompt: String = "",
            optionsJSON: String = "{}",
            providerRequestID: String? = nil,
            resultResourceID: String? = nil,
            resultThumbnailResourceID: String? = nil,
            errorCode: String? = nil,
            errorMessage: String? = nil,
            attemptCount: Int = 0,
            startedAt: Date? = nil,
            completedAt: Date? = nil,
            createdAt: Date = .now,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.sourceGenerationID = sourceGenerationID
            self.providerID = providerID
            self.providerModelID = providerModelID
            self.statusCode = statusCode
            self.prompt = prompt
            self.optionsJSON = optionsJSON
            self.providerRequestID = providerRequestID
            self.resultResourceID = resultResourceID
            self.resultThumbnailResourceID = resultThumbnailResourceID
            self.errorCode = errorCode
            self.errorMessage = errorMessage
            self.attemptCount = attemptCount
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.personInputs = []
            self.garmentInputs = []
        }

        var resolvedStatus: ResolvedCode<GenerationStatus> { ResolvedCode(statusCode) }

        func setStatus(_ status: GenerationStatus, at date: Date = .now) {
            statusCode = status.rawValue
            updatedAt = date
        }

        func markUpdated(at date: Date = .now) { updatedAt = date }
    }

    @Model
    final class GenerationPersonInput {
        @Attribute(.unique) private(set) var id: UUID
        var generation: GenerationRecord
        var personProfile: PersonProfile?
        private(set) var personProfileID: UUID
        var personNameSnapshot: String
        var personImage: PersonImage?
        private(set) var personImageID: UUID
        var resourceIDSnapshot: String
        var sortOrder: Int
        private(set) var createdAt: Date
        private(set) var updatedAt: Date

        init(
            id: UUID = UUID(),
            generation: GenerationRecord,
            personProfile: PersonProfile?,
            personProfileID: UUID,
            personNameSnapshot: String = "",
            personImage: PersonImage?,
            personImageID: UUID,
            resourceIDSnapshot: String,
            sortOrder: Int = 0,
            createdAt: Date = .now,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.generation = generation
            self.personProfile = personProfile
            self.personProfileID = personProfileID
            self.personNameSnapshot = personNameSnapshot
            self.personImage = personImage
            self.personImageID = personImageID
            self.resourceIDSnapshot = resourceIDSnapshot
            self.sortOrder = sortOrder
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
        }

        func markUpdated(at date: Date = .now) { updatedAt = date }
    }

    @Model
    final class GenerationGarmentInput {
        @Attribute(.unique) private(set) var id: UUID
        var generation: GenerationRecord
        var clothingItem: ClothingItem?
        private(set) var clothingItemID: UUID
        var clothingNameSnapshot: String
        var categoryCodeSnapshot: String
        var slotCode: String
        var resourceIDSnapshot: String
        var sortOrder: Int
        private(set) var createdAt: Date
        private(set) var updatedAt: Date

        init(
            id: UUID = UUID(),
            generation: GenerationRecord,
            clothingItem: ClothingItem?,
            clothingItemID: UUID,
            clothingNameSnapshot: String = "",
            categoryCodeSnapshot: String = ClothingCategory.other.rawValue,
            slotCode: String,
            resourceIDSnapshot: String,
            sortOrder: Int = 0,
            createdAt: Date = .now,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.generation = generation
            self.clothingItem = clothingItem
            self.clothingItemID = clothingItemID
            self.clothingNameSnapshot = clothingNameSnapshot
            self.categoryCodeSnapshot = categoryCodeSnapshot
            self.slotCode = slotCode
            self.resourceIDSnapshot = resourceIDSnapshot
            self.sortOrder = sortOrder
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
        }

        var resolvedSlot: ResolvedCode<TryOnSlot> { ResolvedCode(slotCode) }

        func markUpdated(at date: Date = .now) { updatedAt = date }
    }
}

typealias ClothingItem = WardrobeSchemaV1.ClothingItem
typealias PersonProfile = WardrobeSchemaV1.PersonProfile
typealias PersonImage = WardrobeSchemaV1.PersonImage
typealias Outfit = WardrobeSchemaV1.Outfit
typealias OutfitItem = WardrobeSchemaV1.OutfitItem
typealias GenerationRecord = WardrobeSchemaV1.GenerationRecord
typealias GenerationPersonInput = WardrobeSchemaV1.GenerationPersonInput
typealias GenerationGarmentInput = WardrobeSchemaV1.GenerationGarmentInput

enum WardrobeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [WardrobeSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
