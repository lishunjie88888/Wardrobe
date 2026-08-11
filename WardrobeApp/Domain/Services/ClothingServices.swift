import Foundation

protocol ClothingAssetImporting: Sendable {
    func importImage(from sourceURL: URL, for owner: StorageOwner) async throws -> StoredImageResources
    func deleteResourceDirectory(for owner: StorageOwner) async throws
}

protocol ClothingAssetDeleting: Sendable {
    func deleteResourceDirectory(for owner: StorageOwner) async throws
}

protocol ClothingImageLoading: Sendable {
    func data(for resourceID: StorageResourceID) async throws -> Data
}

@MainActor
protocol ClothingImportPersisting {
    func insertAndSave(_ item: ClothingItem) throws
}

@MainActor
protocol ClothingManagingPersisting {
    func clothingItems(matching query: ClothingQuery) throws -> [ClothingRecord]
    func updateClothing(id: UUID, draft: ClothingDraft, at date: Date) throws -> ClothingRecord
    func setClothingFavorite(id: UUID, isFavorite: Bool, at date: Date) throws -> ClothingRecord
    func setClothingArchived(id: UUID, archived: Bool, at date: Date) throws -> ClothingRecord
}

extension SwiftDataWardrobeRepository: ClothingImportPersisting, ClothingManagingPersisting {}

extension StorageService: ClothingAssetImporting, ClothingAssetDeleting, ClothingImageLoading {
    func data(for resourceID: StorageResourceID) async throws -> Data { try read(resourceID) }
}

@MainActor
protocol ResourceReferenceInspecting {
    func referencedResources(in candidates: Set<StorageResourceID>) throws -> Set<StorageResourceID>
}

@MainActor
final class ResourceReferenceInspector: ResourceReferenceInspecting {
    private let repository: any ClothingRepository

    init(repository: any ClothingRepository) { self.repository = repository }

    func referencedResources(in candidates: Set<StorageResourceID>) throws -> Set<StorageResourceID> {
        let persisted = try repository.allPersistedResourceIDStrings()
        return Set(candidates.filter { persisted.contains($0.rawValue) })
    }
}

struct ClothingServiceFailure: Error, LocalizedError {
    let primaryError: any Error
    let cleanupIssues: [StorageCleanupIssue]

    var errorDescription: String? { primaryError.localizedDescription }
}

@MainActor
final class ImportClothingService {
    private let repository: any ClothingImportPersisting
    private let storage: any ClothingAssetImporting
    private let imageProcessing: any ImageProcessingServing

    init(
        repository: any ClothingImportPersisting,
        storage: any ClothingAssetImporting,
        imageProcessing: any ImageProcessingServing
    ) {
        self.repository = repository
        self.storage = storage
        self.imageProcessing = imageProcessing
    }

    func importClothing(from sourceURL: URL, draft: ClothingDraft) async throws -> ClothingRecord {
        let normalized = try draft.normalized()
        let id = UUID()
        let owner = StorageOwner(kind: .garment, id: id)
        var filesystemWasPublished = false
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessedSecurityScope { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try Task.checkCancellation()
            let imported = try await storage.importImage(from: sourceURL, for: owner)
            filesystemWasPublished = true
            try Task.checkCancellation()
            let processed = try await imageProcessing.process(
                originalResourceID: imported.original,
                preset: .garment
            )
            try Task.checkCancellation()
            let now = Date.now
            let item = ClothingItem(
                id: id,
                name: normalized.name,
                notes: normalized.notes,
                categoryCode: normalized.categoryCode,
                subcategoryCode: normalized.subcategoryCode,
                brand: normalized.brand,
                colorCodes: normalized.colorCodes,
                seasonCodes: normalized.seasonCodes,
                styleCodes: normalized.styleCodes,
                materials: normalized.materials,
                tags: normalized.tags,
                isFavorite: normalized.isFavorite,
                originalResourceID: imported.original.rawValue,
                processedResourceID: processed.processedResourceID.rawValue,
                thumbnailResourceID: processed.thumbnailResourceID.rawValue,
                createdAt: now
            )
            try repository.insertAndSave(item)
            return ClothingRecord(
                id: id,
                draft: normalized,
                originalResourceID: imported.original,
                processedResourceID: processed.processedResourceID,
                thumbnailResourceID: processed.thumbnailResourceID,
                archivedAt: nil,
                createdAt: now,
                updatedAt: now
            )
        } catch {
            var issues: [StorageCleanupIssue] = []
            if filesystemWasPublished {
                do {
                    try await storage.deleteResourceDirectory(for: owner)
                } catch let cleanupError {
                    issues.append(StorageCleanupIssue(
                        actionDescription: "delete garment owner \(id.uuidString.lowercased())",
                        errorDescription: cleanupError.localizedDescription
                    ))
                }
            }
            if error is CancellationError, issues.isEmpty { throw CancellationError() }
            throw ClothingServiceFailure(primaryError: error, cleanupIssues: issues)
        }
    }
}

@MainActor
final class ClothingManagementService {
    private let repository: any ClothingManagingPersisting

    init(repository: any ClothingManagingPersisting) { self.repository = repository }

    func clothing(matching query: ClothingQuery) throws -> [ClothingRecord] {
        try repository.clothingItems(matching: query)
    }

    func update(id: UUID, draft: ClothingDraft) throws -> ClothingRecord {
        try repository.updateClothing(id: id, draft: draft, at: .now)
    }

    func setFavorite(id: UUID, value: Bool) throws -> ClothingRecord {
        try repository.setClothingFavorite(id: id, isFavorite: value, at: .now)
    }

    func setArchived(id: UUID, value: Bool) throws -> ClothingRecord {
        try repository.setClothingArchived(id: id, archived: value, at: .now)
    }
}

@MainActor
final class ClothingDeletionService {
    private let repository: any ClothingRepository
    private let inspector: any ResourceReferenceInspecting
    private let storage: any ClothingAssetDeleting

    init(
        repository: any ClothingRepository,
        inspector: any ResourceReferenceInspecting,
        storage: any ClothingAssetDeleting
    ) {
        self.repository = repository
        self.inspector = inspector
        self.storage = storage
    }

    func impact(for clothingID: UUID) throws -> ClothingDeleteImpact {
        try repository.clothingDeleteImpact(id: clothingID)
    }

    func permanentlyDelete(clothingID: UUID) async throws -> ClothingDeleteResult {
        guard let item = try repository.clothingItem(id: clothingID) else {
            throw WardrobeRepositoryError.modelNotFound(model: "ClothingItem", id: clothingID)
        }
        let impact = try repository.clothingDeleteImpact(id: clothingID)
        var candidates = Set<StorageResourceID>()
        candidates.insert(try StorageResourceID(rawValue: item.originalResourceID))
        if let value = item.processedResourceID { candidates.insert(try StorageResourceID(rawValue: value)) }
        if let value = item.thumbnailResourceID { candidates.insert(try StorageResourceID(rawValue: value)) }

        // Metadata is committed first. SwiftData nullifies live relationships while
        // the immutable snapshot fields remain available to Outfit/Generation history.
        try repository.deleteClothingItem(id: clothingID)

        var issues: [StorageCleanupIssue] = []
        let retained: Set<StorageResourceID>
        do {
            retained = try inspector.referencedResources(in: candidates)
        } catch {
            issues.append(StorageCleanupIssue(
                actionDescription: "inspect surviving resource references",
                errorDescription: error.localizedDescription
            ))
            return ClothingDeleteResult(
                impact: impact,
                retainedResources: Array(candidates).sorted { $0.rawValue < $1.rawValue },
                cleanupIssues: issues
            )
        }

        // Keep the complete owner directory if any file is still referenced. This
        // conservative rule prevents directory-level cleanup from removing snapshots.
        if retained.isEmpty {
            do {
                try await storage.deleteResourceDirectory(for: StorageOwner(kind: .garment, id: clothingID))
            } catch {
                issues.append(StorageCleanupIssue(
                    actionDescription: "delete unreferenced garment resources",
                    errorDescription: error.localizedDescription
                ))
            }
        }
        return ClothingDeleteResult(
            impact: impact,
            retainedResources: Array(retained).sorted { $0.rawValue < $1.rawValue },
            cleanupIssues: issues
        )
    }
}
