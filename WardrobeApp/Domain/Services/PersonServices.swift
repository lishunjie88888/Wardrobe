import Foundation

typealias PersonAssetImporting = ManagedImageAssetImporting
typealias PersonAssetDeleting = ManagedImageAssetDeleting
typealias PersonImageLoading = ManagedImageLoading

@MainActor
protocol PersonImportPersisting {
    func personProfile(id: UUID) throws -> PersonProfile?
    func insertPersonImageAndSave(_ image: PersonImage, at date: Date) throws -> PersonImageRecord
}

@MainActor
protocol PersonManagingPersisting {
    func personProfiles(archive: PersonArchiveFilter) throws -> [PersonProfileRecord]
    func createPersonProfile(draft: PersonDraft, at date: Date) throws -> PersonProfileRecord
    func updatePersonProfile(id: UUID, draft: PersonDraft, at date: Date) throws -> PersonProfileRecord
    func setPersonProfileArchived(id: UUID, archived: Bool, at date: Date) throws -> PersonProfileRecord
    func setDefaultPersonProfile(id: UUID, at date: Date) throws
    func setPrimaryPersonImage(id: UUID, for profileID: UUID, at date: Date) throws
    func defaultPersonReferenceSet() throws -> PersonReferenceSet?
    func personReferenceSet(profileID: UUID) throws -> PersonReferenceSet?
}

extension SwiftDataWardrobeRepository: PersonImportPersisting, PersonManagingPersisting {}

struct PersonServiceFailure: Error, LocalizedError {
    let primaryError: any Error
    let cleanupIssues: [StorageCleanupIssue]

    var errorDescription: String? { primaryError.localizedDescription }
}

@MainActor
final class PersonManagementService {
    private let repository: any PersonManagingPersisting

    init(repository: any PersonManagingPersisting) { self.repository = repository }

    func profiles(archive: PersonArchiveFilter = .active) throws -> [PersonProfileRecord] {
        try repository.personProfiles(archive: archive)
    }

    func create(draft: PersonDraft) throws -> PersonProfileRecord {
        try repository.createPersonProfile(draft: draft, at: .now)
    }

    func update(id: UUID, draft: PersonDraft) throws -> PersonProfileRecord {
        try repository.updatePersonProfile(id: id, draft: draft, at: .now)
    }

    func setArchived(id: UUID, value: Bool) throws -> PersonProfileRecord {
        try repository.setPersonProfileArchived(id: id, archived: value, at: .now)
    }

    func setDefault(id: UUID) throws {
        try repository.setDefaultPersonProfile(id: id, at: .now)
    }

    func setPrimary(imageID: UUID, profileID: UUID) throws {
        try repository.setPrimaryPersonImage(id: imageID, for: profileID, at: .now)
    }

    func defaultReferenceSet() throws -> PersonReferenceSet? {
        try repository.defaultPersonReferenceSet()
    }

    func referenceSet(profileID: UUID) throws -> PersonReferenceSet? {
        try repository.personReferenceSet(profileID: profileID)
    }
}

@MainActor
final class ImportPersonImageService {
    private let repository: any PersonImportPersisting
    private let storage: any PersonAssetImporting
    private let imageProcessing: any ImageProcessingServing

    init(
        repository: any PersonImportPersisting,
        storage: any PersonAssetImporting,
        imageProcessing: any ImageProcessingServing
    ) {
        self.repository = repository
        self.storage = storage
        self.imageProcessing = imageProcessing
    }

    func importImage(from sourceURL: URL, profileID: UUID) async throws -> PersonImageRecord {
        guard let profile = try repository.personProfile(id: profileID) else {
            throw WardrobeRepositoryError.modelNotFound(model: "PersonProfile", id: profileID)
        }
        let id = UUID()
        let owner = StorageOwner(kind: .person, id: id)
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
                preset: .person
            )
            try Task.checkCancellation()
            let now = Date.now
            let image = PersonImage(
                id: id,
                profile: profile,
                isPrimary: profile.images.isEmpty,
                originalResourceID: imported.original.rawValue,
                processedResourceID: processed.processedResourceID.rawValue,
                thumbnailResourceID: processed.thumbnailResourceID.rawValue,
                pixelWidth: processed.processed.pixelWidth,
                pixelHeight: processed.processed.pixelHeight,
                createdAt: now
            )
            return try repository.insertPersonImageAndSave(image, at: now)
        } catch {
            var issues: [StorageCleanupIssue] = []
            if filesystemWasPublished {
                do {
                    try await storage.deleteResourceDirectory(for: owner)
                } catch {
                    issues.append(StorageCleanupIssue(
                        actionDescription: "delete person image owner \(id.uuidString.lowercased())",
                        errorDescription: error.localizedDescription
                    ))
                }
            }
            if error is CancellationError, issues.isEmpty { throw CancellationError() }
            throw PersonServiceFailure(primaryError: error, cleanupIssues: issues)
        }
    }
}

@MainActor
final class PersonImageDeletionService {
    private let repository: any PersonRepository
    private let inspector: any ResourceReferenceInspecting
    private let storage: any PersonAssetDeleting

    init(repository: any PersonRepository, inspector: any ResourceReferenceInspecting, storage: any PersonAssetDeleting) {
        self.repository = repository
        self.inspector = inspector
        self.storage = storage
    }

    func impact(for imageID: UUID) throws -> PersonImageDeleteImpact {
        try repository.personImageDeleteImpact(id: imageID)
    }

    func permanentlyDelete(imageID: UUID) async throws -> PersonDeletionResult {
        guard let image = try repository.personImage(id: imageID) else {
            throw WardrobeRepositoryError.modelNotFound(model: "PersonImage", id: imageID)
        }
        let candidates = try Self.resources(for: image)
        try repository.deletePersonImage(id: imageID, at: .now)
        return await clean(candidates: candidates, ownerIDs: [imageID])
    }

    private func clean(candidates: Set<StorageResourceID>, ownerIDs: [UUID]) async -> PersonDeletionResult {
        var issues: [StorageCleanupIssue] = []
        let retained: Set<StorageResourceID>
        do {
            retained = try inspector.referencedResources(in: candidates)
        } catch {
            issues.append(StorageCleanupIssue(actionDescription: "inspect surviving resource references", errorDescription: error.localizedDescription))
            return PersonDeletionResult(retainedResources: candidates.sorted(by: Self.sortResources), cleanupIssues: issues)
        }
        for ownerID in ownerIDs {
            let ownerCandidates = candidates.filter { $0.owner.id == ownerID }
            guard retained.isDisjoint(with: ownerCandidates) else { continue }
            do {
                try await storage.deleteResourceDirectory(for: StorageOwner(kind: .person, id: ownerID))
            } catch {
                issues.append(StorageCleanupIssue(actionDescription: "delete unreferenced person image resources", errorDescription: error.localizedDescription))
            }
        }
        return PersonDeletionResult(retainedResources: retained.sorted(by: Self.sortResources), cleanupIssues: issues)
    }

    fileprivate static func resources(for image: PersonImage) throws -> Set<StorageResourceID> {
        var result = Set([try StorageResourceID(rawValue: image.originalResourceID)])
        if let value = image.processedResourceID { result.insert(try StorageResourceID(rawValue: value)) }
        if let value = image.thumbnailResourceID { result.insert(try StorageResourceID(rawValue: value)) }
        return result
    }

    fileprivate static func sortResources(_ left: StorageResourceID, _ right: StorageResourceID) -> Bool {
        left.rawValue < right.rawValue
    }
}

@MainActor
final class PersonProfileDeletionService {
    private let repository: any PersonRepository
    private let inspector: any ResourceReferenceInspecting
    private let storage: any PersonAssetDeleting

    init(repository: any PersonRepository, inspector: any ResourceReferenceInspecting, storage: any PersonAssetDeleting) {
        self.repository = repository
        self.inspector = inspector
        self.storage = storage
    }

    func impact(for profileID: UUID) throws -> PersonProfileDeleteImpact {
        try repository.personProfileDeleteImpact(id: profileID)
    }

    func permanentlyDelete(profileID: UUID) async throws -> PersonDeletionResult {
        guard let profile = try repository.personProfile(id: profileID) else {
            throw WardrobeRepositoryError.modelNotFound(model: "PersonProfile", id: profileID)
        }
        let images = Array(profile.images)
        let candidates = try images.reduce(into: Set<StorageResourceID>()) { partial, image in
            partial.formUnion(try PersonImageDeletionService.resources(for: image))
        }
        let ownerIDs = images.map(\.id)
        try repository.deletePersonProfileAndSave(id: profileID)

        var issues: [StorageCleanupIssue] = []
        let retained: Set<StorageResourceID>
        do {
            retained = try inspector.referencedResources(in: candidates)
        } catch {
            issues.append(StorageCleanupIssue(actionDescription: "inspect surviving resource references", errorDescription: error.localizedDescription))
            return PersonDeletionResult(retainedResources: candidates.sorted(by: PersonImageDeletionService.sortResources), cleanupIssues: issues)
        }
        for ownerID in ownerIDs {
            let ownerCandidates = candidates.filter { $0.owner.id == ownerID }
            guard retained.isDisjoint(with: ownerCandidates) else { continue }
            do {
                try await storage.deleteResourceDirectory(for: StorageOwner(kind: .person, id: ownerID))
            } catch {
                issues.append(StorageCleanupIssue(actionDescription: "delete unreferenced person image resources", errorDescription: error.localizedDescription))
            }
        }
        return PersonDeletionResult(
            retainedResources: retained.sorted(by: PersonImageDeletionService.sortResources),
            cleanupIssues: issues
        )
    }
}
