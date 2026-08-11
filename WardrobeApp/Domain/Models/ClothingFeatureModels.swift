import Foundation

enum ClothingArchiveFilter: String, CaseIterable, Sendable {
    case active
    case archived
    case all
}

enum ClothingSort: String, CaseIterable, Sendable {
    case newest
    case recentlyUpdated
    case name
    case favoritesFirst
}

struct ClothingQuery: Equatable, Sendable {
    var searchText = ""
    var categoryCode: String?
    var seasonCode: String?
    var colorCode: String?
    var styleCode: String?
    var favoritesOnly = false
    var archive: ClothingArchiveFilter = .active
    var sort: ClothingSort = .newest
    var fetchLimit = 250

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        categoryCode != nil || seasonCode != nil || colorCode != nil || styleCode != nil ||
        favoritesOnly || archive != .active
    }
}

struct ClothingDraft: Equatable, Sendable {
    var name = ""
    var categoryCode = ClothingCategory.other.rawValue
    var subcategoryCode: String?
    var brand: String?
    var colorCodes: [String] = []
    var seasonCodes: [String] = []
    var styleCodes: [String] = []
    var materials: [String] = []
    var tags: [String] = []
    var isFavorite = false
    var notes: String?

    func normalized() throws -> ClothingDraft {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { throw ClothingValidationError.emptyName }
        copy.categoryCode = Self.trimmed(categoryCode) ?? ClothingCategory.other.rawValue
        copy.subcategoryCode = Self.trimmed(subcategoryCode)
        copy.brand = Self.trimmed(brand)
        copy.notes = Self.trimmed(notes)
        copy.colorCodes = Self.normalizedList(colorCodes)
        copy.seasonCodes = Self.normalizedList(seasonCodes)
        copy.styleCodes = Self.normalizedList(styleCodes)
        copy.materials = Self.normalizedList(materials)
        copy.tags = Self.normalizedList(tags)
        return copy
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func normalizedList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { trimmed($0) }.filter { seen.insert($0.localizedLowercase).inserted }
    }
}

enum ClothingValidationError: Error, Equatable, LocalizedError {
    case emptyName

    var errorDescription: String? { "请填写衣物名称。" }
}

struct ClothingRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    var draft: ClothingDraft
    let originalResourceID: StorageResourceID
    let processedResourceID: StorageResourceID?
    let thumbnailResourceID: StorageResourceID?
    let archivedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    var isArchived: Bool { archivedAt != nil }
    var preferredDisplayResourceID: StorageResourceID? { processedResourceID ?? thumbnailResourceID }
}

struct ClothingDeleteImpact: Equatable, Sendable {
    let clothingID: UUID
    let outfitSnapshotCount: Int
    let generationSnapshotCount: Int

    var hasHistoricalReferences: Bool { outfitSnapshotCount > 0 || generationSnapshotCount > 0 }
}

struct ClothingDeleteResult: Equatable, Sendable {
    let impact: ClothingDeleteImpact
    let retainedResources: [StorageResourceID]
    let cleanupIssues: [StorageCleanupIssue]
}
