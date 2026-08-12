import Foundation

enum GenerationStatusFilter: String, CaseIterable, Sendable {
    case all
    case succeeded
    case failed
    case cancelled
    case inProgress
}

struct GenerationHistoryQuery: Equatable, Sendable {
    var status: GenerationStatusFilter = .all
    var providerID: String?
    var fetchLimit = 500

    var hasActiveFilters: Bool { status != .all || providerID != nil }
}

enum GenerationDisplayStatus: Equatable, Sendable {
    case known(GenerationStatus)
    case interrupted
    case unknown(String)

    var isTerminal: Bool {
        switch self {
        case .known(let status): status.isTerminal
        case .interrupted: true
        case .unknown: false
        }
    }
}

struct GenerationPersonSnapshotRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let personProfileID: UUID
    let personImageID: UUID
    let personNameSnapshot: String
    let resourceIDSnapshot: StorageResourceID?
    let sortOrder: Int
    let hasCurrentProfile: Bool
    let currentProfileIsActive: Bool
    let hasCurrentImage: Bool
}

struct GenerationGarmentSnapshotRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let clothingItemID: UUID
    let clothingNameSnapshot: String
    let categoryCodeSnapshot: String
    let slotCode: String
    let resourceIDSnapshot: StorageResourceID?
    let sortOrder: Int
    let hasCurrentClothing: Bool
    let currentClothingIsActive: Bool
    let currentClothingName: String?
    let currentCategoryCode: String?

    var resolvedSlot: TryOnSlot? { TryOnSlot(rawValue: slotCode) }
}

struct GenerationHistoryRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let providerID: String
    let status: GenerationDisplayStatus
    let thumbnailResourceID: StorageResourceID?
    let personNameSnapshot: String
    let garmentSummary: String
    let createdAt: Date
    let completedAt: Date?
}

struct GenerationDetailRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceGenerationID: UUID?
    let sourceExists: Bool
    let providerID: String
    let providerModelID: String?
    let status: GenerationDisplayStatus
    let prompt: String
    let optionsText: String
    let providerRequestID: String?
    let resultResourceID: StorageResourceID?
    let resultThumbnailResourceID: StorageResourceID?
    let errorCode: String?
    let safeErrorMessage: String?
    let attemptCount: Int
    let startedAt: Date?
    let completedAt: Date?
    let createdAt: Date
    let persons: [GenerationPersonSnapshotRecord]
    let garments: [GenerationGarmentSnapshotRecord]
}

enum GenerationUnavailableReason: String, Equatable, Sendable {
    case archived
    case missing
    case invalidSlot
    case incompatible
    case missingResource
}

struct GenerationUnavailableInput: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let reason: GenerationUnavailableReason
}

struct GenerationRegenerateRequest: Equatable, Sendable {
    let sourceGenerationID: UUID
    let personProfileID: UUID
    let selectedPersonImageIDs: [UUID]
    let garments: [OutfitLoadItem]
    let historicalPrompt: String
    let historicalOptionsText: String
}

struct GenerationRegeneratePreflight: Equatable, Sendable {
    let request: GenerationRegenerateRequest?
    let unavailableInputs: [GenerationUnavailableInput]
    var canRegenerate: Bool { request != nil && unavailableInputs.isEmpty }
}

struct GenerationSaveOutfitPreflight: Equatable, Sendable {
    let items: [OutfitCreationItem]
    let unavailableInputs: [GenerationUnavailableInput]
    var canSave: Bool { !items.isEmpty && unavailableInputs.isEmpty }
}

struct GenerationDeleteImpact: Equatable, Sendable {
    let generationID: UUID
    let personInputCount: Int
    let garmentInputCount: Int
    let resultCleanupCandidateCount: Int
    let canDelete: Bool
}

struct GenerationDeleteResult: Equatable, Sendable {
    let cleanupIssueCount: Int
}

enum GenerationHistoryServiceError: Error, Equatable, LocalizedError {
    case notFound
    case nonterminalRecord
    case regenerateUnavailable
    case saveOutfitUnavailable

    var errorDescription: String? {
        switch self {
        case .notFound: "生成记录不存在。"
        case .nonterminalRecord: "进行中的生成记录不能从历史页面删除或重新生成。"
        case .regenerateUnavailable: "此记录的部分历史输入当前不可用，无法完整重新生成。"
        case .saveOutfitUnavailable: "此生成中的部分衣物当前不可用于创建穿搭。"
        }
    }
}

enum GenerationHistoryPresentation {
    static func providerName(_ providerID: String) -> String {
        switch providerID {
        case "mock": "Mock 测试"
        case "external-chatgpt-manual": "ChatGPT 手动生成"
        default: "Provider: \(providerID)"
        }
    }
}
