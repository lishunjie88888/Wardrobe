import Foundation

enum OutfitArchiveFilter: String, CaseIterable, Sendable {
    case active
    case archived
    case all
}

enum OutfitSort: String, CaseIterable, Sendable {
    case recentlyUpdated
    case newest
    case name
    case favoritesFirst
}

struct OutfitQuery: Equatable, Sendable {
    var searchText = ""
    var favoritesOnly = false
    var archive: OutfitArchiveFilter = .active
    var sort: OutfitSort = .recentlyUpdated
    var fetchLimit = 250

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        favoritesOnly || archive != .active
    }
}

struct OutfitDraft: Equatable, Sendable {
    var name = "未命名穿搭"
    var notes: String?
    var isFavorite = false

    func normalized() -> OutfitDraft {
        var copy = self
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = normalizedName.isEmpty ? "未命名穿搭" : normalizedName
        copy.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.notes?.isEmpty == true { copy.notes = nil }
        return copy
    }
}

struct OutfitCreationItem: Equatable, Sendable {
    let clothingItemID: UUID
    let slotCode: String
    let sortOrder: Int
}

struct OutfitItemRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let clothingItemID: UUID
    let hasCurrentClothing: Bool
    let currentClothingIsActive: Bool
    let currentClothingName: String?
    let currentThumbnailResourceID: StorageResourceID?
    let currentCategoryCode: String?
    let clothingNameSnapshot: String
    let thumbnailResourceIDSnapshot: StorageResourceID?
    let slotCode: String
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    var resolvedSlot: TryOnSlot? { TryOnSlot(rawValue: slotCode) }
    var displayName: String { currentClothingName ?? clothingNameSnapshot }
    var preferredThumbnailResourceID: StorageResourceID? {
        hasCurrentClothing ? (currentThumbnailResourceID ?? thumbnailResourceIDSnapshot) : thumbnailResourceIDSnapshot
    }
}

struct OutfitRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    var draft: OutfitDraft
    let coverResourceID: StorageResourceID?
    let archivedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let items: [OutfitItemRecord]

    var isArchived: Bool { archivedAt != nil }
}

enum OutfitUnavailableReason: String, Equatable, Sendable {
    case archived
    case missing
    case invalidSlot
    case incompatible
}

struct OutfitUnavailableItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let slotCode: String
    let reason: OutfitUnavailableReason
}

struct OutfitLoadItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let clothingItemID: UUID
    let slot: TryOnSlot
    let sortOrder: Int
}

struct OutfitLoadResult: Equatable, Sendable {
    let outfitID: UUID
    let outfitName: String
    let availableItems: [OutfitLoadItem]
    let unavailableItems: [OutfitUnavailableItem]

    var requiresConfirmation: Bool { !unavailableItems.isEmpty }
    var canLoad: Bool { !availableItems.isEmpty }
    func unavailableCount(_ reason: OutfitUnavailableReason) -> Int {
        unavailableItems.filter { $0.reason == reason }.count
    }
}

enum OutfitServiceError: Error, Equatable, LocalizedError {
    case emptyOutfit
    case invalidSlot(String)
    case duplicateSingleSlot(TryOnSlot)
    case duplicateClothing(UUID)
    case clothingUnavailable(UUID)
    case clothingRelationshipMismatch(UUID)
    case invalidSnapshotName(UUID)
    case noLoadableItems

    var errorDescription: String? {
        switch self {
        case .emptyOutfit: "当前搭配中还没有衣物。"
        case .invalidSlot: "穿搭包含无法识别的试衣槽位。"
        case .duplicateSingleSlot: "同一个单件槽位不能保存多件衣物。"
        case .duplicateClothing: "同一件衣物不能在穿搭中重复保存。"
        case .clothingUnavailable: "当前搭配中有衣物已不可用。"
        case .clothingRelationshipMismatch: "衣物关系与稳定标识不一致。"
        case .invalidSnapshotName: "衣物名称快照无效。"
        case .noLoadableItems: "此穿搭目前没有可载入的衣物。"
        }
    }
}
