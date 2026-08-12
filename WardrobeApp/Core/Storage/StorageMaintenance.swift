import Foundation

/// Injectable capacity provider so disk-full conditions can be tested
/// deterministically without filling the disk.
protocol StorageCapacityChecking: Sendable {
    func availableBytes(at url: URL) throws -> Int64
}

struct SystemStorageCapacity: StorageCapacityChecking {
    func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

enum StorageCapacityRequirement {
    /// Critical persistent writes fail before touching any file when the
    /// volume has less free space than this floor. The staging + atomic move
    /// flow already prevents partial files; the floor makes the failure
    /// deterministic and visible to the caller.
    static let minimumWriteFreeBytes: Int64 = 8 * 1_048_576
}

/// Cache policy for the disposable `cache/` namespaces. Cache content is
/// rebuildable, never enters backups, and eviction never touches SwiftData.
struct CachePolicy: Equatable, Sendable {
    static let wardrobeDefault = CachePolicy()

    var version: Int
    var maximumBytes: Int64

    init(version: Int = 1, maximumBytes: Int64 = 512 * 1_048_576) {
        self.version = version
        self.maximumBytes = maximumBytes
    }
}

struct CacheCleanupResult: Equatable, Sendable {
    let removedFileCount: Int
    let removedBytes: Int64
}

/// Staging entries older than the grace period are presumed abandoned at
/// startup. Only direct children of `staging/` with a canonical UUID name are
/// candidates; restore/migration transactions live outside `staging/` and are
/// never touched.
struct StagingExpirationPolicy: Equatable, Sendable {
    static let wardrobeDefault = StagingExpirationPolicy()

    var gracePeriod: TimeInterval

    init(gracePeriod: TimeInterval = 24 * 60 * 60) {
        self.gracePeriod = gracePeriod
    }
}

struct StagingRecoveryResult: Equatable, Sendable {
    let removedOperationCount: Int
    let removedFileCount: Int
    let skippedNonOperationEntries: [String]
}

enum OrphanCleanupPolicy {
    /// A resource must be unreferenced for at least this long before it
    /// becomes an eligible cleanup candidate. Nothing is ever deleted
    /// automatically: the report is read-only and cleanup requires an
    /// explicit, user-confirmed request.
    static let gracePeriod: TimeInterval = 7 * 24 * 60 * 60
}

struct OrphanReport: Equatable, Sendable {
    /// Referenced by SwiftData but missing on disk.
    let missingReferencedResources: [StorageResourceID]
    /// Present on disk but not referenced by any record.
    let unreferencedCandidates: [StorageResourceID]
    /// Unreferenced AND older than the cleanup grace period.
    let eligibleCleanupCandidates: [StorageResourceID]
    let scannedResourceCount: Int
}

struct OrphanCleanupResult: Equatable, Sendable {
    let deletedResources: [StorageResourceID]
    let retainedResources: [StorageResourceID]
    let failedResources: [StorageCleanupIssue]
}

/// Storage-side scanning primitives used by the read-only orphan report and
/// the explicitly confirmed cleanup. Only valid `StorageResourceID` files
/// inside owner directories are ever reported or deleted.
protocol OrphanStorageScanning: Sendable {
    func scanManagedResources() async throws -> Set<StorageResourceID>
    func modificationDate(of resourceID: StorageResourceID) async throws -> Date?
    func deleteUnreferencedFile(_ resourceID: StorageResourceID) async throws
}

/// Read-only orphan scanning plus a conservative, explicitly confirmed
/// cleanup path. The default is report-only: nothing is ever deleted without
/// a separate call, and that call re-checks references and grace period at
/// execution time before deleting individual files.
@MainActor
final class OrphanReportService {
    private let repository: any ClothingRepository
    private let storage: any OrphanStorageScanning

    init(repository: any ClothingRepository, storage: any OrphanStorageScanning) {
        self.repository = repository
        self.storage = storage
    }

    func generateReport(
        now: Date = .now,
        gracePeriod: TimeInterval = OrphanCleanupPolicy.gracePeriod
    ) async throws -> OrphanReport {
        let referenced = try repository.allPersistedResourceIDStrings()
        let onDisk = try await storage.scanManagedResources()
        let missing = referenced
            .filter { idString in !onDisk.contains { $0.rawValue == idString } }
            .compactMap { try? StorageResourceID(rawValue: $0) }
            .sorted { $0.rawValue < $1.rawValue }
        let unreferenced = onDisk.filter { !referenced.contains($0.rawValue) }
        var eligible: [StorageResourceID] = []
        for resource in unreferenced {
            guard let date = try? await storage.modificationDate(of: resource) else { continue }
            if now.timeIntervalSince(date) >= gracePeriod { eligible.append(resource) }
        }
        return OrphanReport(
            missingReferencedResources: missing,
            unreferencedCandidates: unreferenced.sorted { $0.rawValue < $1.rawValue },
            eligibleCleanupCandidates: eligible.sorted { $0.rawValue < $1.rawValue },
            scannedResourceCount: onDisk.count
        )
    }

    /// Explicit, user-confirmed cleanup only. The reference set is re-read at
    /// execution time and each candidate is verified against it immediately
    /// before deletion. Deletes individual files only, never directories, and
    /// never touches cache, staging, backups, migration or external packages.
    func deleteEligibleUnreferenced(
        now: Date = .now,
        gracePeriod: TimeInterval = OrphanCleanupPolicy.gracePeriod
    ) async throws -> OrphanCleanupResult {
        let report = try await generateReport(now: now, gracePeriod: gracePeriod)
        let referencedNow = try repository.allPersistedResourceIDStrings()
        var deleted: [StorageResourceID] = []
        var retained: [StorageResourceID] = []
        var failed: [StorageCleanupIssue] = []
        for resource in report.eligibleCleanupCandidates {
            if referencedNow.contains(resource.rawValue) {
                retained.append(resource)
                continue
            }
            do {
                try await storage.deleteUnreferencedFile(resource)
                deleted.append(resource)
            } catch {
                failed.append(StorageCleanupIssue(
                    actionDescription: "delete unreferenced file \(resource.rawValue)",
                    errorDescription: error.localizedDescription
                ))
            }
        }
        return OrphanCleanupResult(
            deletedResources: deleted,
            retainedResources: retained,
            failedResources: failed
        )
    }
}
