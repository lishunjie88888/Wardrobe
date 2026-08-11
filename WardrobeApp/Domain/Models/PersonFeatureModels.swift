import Foundation

enum PersonArchiveFilter: String, CaseIterable, Sendable {
    case active
    case archived
    case all
}

struct PersonDraft: Equatable, Sendable {
    var name = ""
    var notes: String?

    func normalized() throws -> PersonDraft {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw PersonValidationError.emptyName }
        let normalizedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PersonDraft(name: normalizedName, notes: normalizedNotes?.isEmpty == true ? nil : normalizedNotes)
    }
}

enum PersonValidationError: Error, Equatable, LocalizedError {
    case emptyName

    var errorDescription: String? { "请填写人物名称。" }
}

struct PersonImageRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileID: UUID
    let isPrimary: Bool
    let originalResourceID: StorageResourceID
    let processedResourceID: StorageResourceID?
    let thumbnailResourceID: StorageResourceID?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let createdAt: Date
    let updatedAt: Date

    var preferredDisplayResourceID: StorageResourceID? { processedResourceID ?? thumbnailResourceID }
}

struct PersonProfileRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    var draft: PersonDraft
    let isDefault: Bool
    let archivedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let images: [PersonImageRecord]

    var isArchived: Bool { archivedAt != nil }
    var primaryImage: PersonImageRecord? { images.first(where: \.isPrimary) }
    var preferredThumbnailResourceID: StorageResourceID? {
        primaryImage?.thumbnailResourceID ?? primaryImage?.processedResourceID
    }
}

struct PersonReferenceSet: Equatable, Sendable {
    let profileID: UUID
    let primaryImage: PersonImageRecord?
    let additionalImages: [PersonImageRecord]
}

struct PersonImageDeleteImpact: Equatable, Sendable {
    let imageID: UUID
    let generationSnapshotCount: Int
}

struct PersonProfileDeleteImpact: Equatable, Sendable {
    let profileID: UUID
    let imageCount: Int
    let generationProfileSnapshotCount: Int
    let generationImageSnapshotCount: Int

    var hasHistoricalReferences: Bool {
        generationProfileSnapshotCount > 0 || generationImageSnapshotCount > 0
    }
}

struct PersonDeletionResult: Equatable, Sendable {
    let retainedResources: [StorageResourceID]
    let cleanupIssues: [StorageCleanupIssue]
}
