import Foundation
import SwiftData

// MARK: - Transaction

struct RestoreTransaction: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case originalMoved
        case candidateInstalled
        case verifying
        case committed
        case rollingBack
        case rolledBack
        case failed
    }

    let operationID: UUID
    var phase: Phase
    let backupID: UUID
    let sourceLibraryID: UUID
    let sourceLibraryCreatedAt: Date
    let schemaVersion: String
    let storageLayoutVersion: Int
    let recordCounts: BackupRecordCounts
    let assetCount: Int
    let totalAssetBytes: Int64
    let createdAt: Date
}

// MARK: - Transaction Workspace

enum RestoreTransactionWorkspace {
    static let directoryPrefix = "Wardrobe.restore-"
    static let transactionFileName = "transaction.json"
    static let candidateDirectoryName = "candidate"
    static let rollbackDirectoryName = "rollback"
    static let failedDirectoryName = "failed"

    static func workspaceURL(operationID: UUID, parent: URL) -> URL {
        parent.appendingPathComponent("\(directoryPrefix)\(operationID.uuidString.lowercased())", isDirectory: true)
    }

    /// Finds the single pending restore transaction next to the production
    /// root. Multiple workspaces are ambiguous and block startup.
    static func discoverPending(parent: URL, fileManager: FileManager = .default) throws -> URL? {
        var found: URL?
        guard let entries = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for entry in entries where entry.lastPathComponent.hasPrefix(directoryPrefix) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard fileManager.fileExists(
                atPath: transactionURL(in: entry).path
            ) else {
                // A prepare that never completed leaves no transaction; the
                // original library was never touched, so the workspace is safe
                // to discard.
                try? fileManager.removeItem(at: entry)
                continue
            }
            if found != nil {
                throw BackupError.restoreInterrupted
            }
            found = entry
        }
        return found
    }

    static func transactionURL(in workspace: URL) -> URL {
        workspace.appendingPathComponent(transactionFileName)
    }

    static func readTransaction(in workspace: URL) throws -> RestoreTransaction? {
        let url = transactionURL(in: workspace)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try BackupJSON.decoder().decode(RestoreTransaction.self, from: Data(contentsOf: url))
        } catch {
            throw BackupError.restoreInterrupted
        }
    }

    static func writeTransaction(_ transaction: RestoreTransaction, in workspace: URL) throws {
        let data = try BackupJSON.deterministicData(transaction)
        try data.write(to: transactionURL(in: workspace), options: [.atomic])
    }
}

// MARK: - Result Marker

enum RestoreResultMarker {
    static let fileName = "Wardrobe.restore-result.json"

    static func write(
        result: BackupRestoreResult,
        parent: URL,
        fileManager: FileManager = .default
    ) throws {
        struct Marker: Codable {
            let completedAt: Date
            let restoredRecordCounts: BackupRecordCounts
            let restoredAssetCount: Int
            let restoredAssetBytes: Int64
            let rolledBack: Bool
        }
        let marker = Marker(
            completedAt: result.completedAt,
            restoredRecordCounts: result.restoredRecordCounts,
            restoredAssetCount: result.restoredAssetCount,
            restoredAssetBytes: result.restoredAssetBytes,
            rolledBack: result.rolledBack
        )
        let data = try BackupJSON.deterministicData(marker)
        try data.write(to: parent.appendingPathComponent(fileName), options: [.atomic])
    }

    static func read(parent: URL, fileManager: FileManager = .default) -> BackupRestoreResult? {
        let url = parent.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        struct Marker: Codable {
            let completedAt: Date
            let restoredRecordCounts: BackupRecordCounts
            let restoredAssetCount: Int
            let restoredAssetBytes: Int64
            let rolledBack: Bool
        }
        guard let data = try? Data(contentsOf: url),
              let marker = try? BackupJSON.decoder().decode(Marker.self, from: data)
        else { return nil }
        return BackupRestoreResult(
            completedAt: marker.completedAt,
            restoredRecordCounts: marker.restoredRecordCounts,
            restoredAssetCount: marker.restoredAssetCount,
            restoredAssetBytes: marker.restoredAssetBytes,
            rolledBack: marker.rolledBack
        )
    }
}

// MARK: - Coordinator (candidate preparation)

actor LibraryRestoreCoordinator {
    private let configuration: StorageConfiguration
    private let capacity: any BackupCapacityChecking

    init(
        configuration: StorageConfiguration,
        capacity: any BackupCapacityChecking = SystemBackupCapacity()
    ) {
        self.configuration = configuration
        self.capacity = capacity
    }

    /// Validates the package, then builds and fully validates an isolated
    /// candidate library in a sibling transaction workspace. The live library
    /// is untouched until the app restarts and applies the transaction.
    func prepare(
        packageURL: URL,
        progress: @Sendable (BackupPhase) -> Void = { _ in }
    ) async throws -> BackupRestoreReadyInfo {
        try Task.checkCancellation()
        progress(.preparingRestore)

        let root = configuration.rootURL.standardizedFileURL
        let parent = root.deletingLastPathComponent()

        guard try RestoreTransactionWorkspace.discoverPending(parent: parent) == nil else {
            throw BackupError.pendingRestoreExists
        }

        let validation = try BackupValidator().validate(packageURL: packageURL)

        // Disk space: candidate bytes + current rollback snapshot + margin.
        let currentLibraryBytes = try BackupFileSize.bytes(in: root)
        let required = BackupCapacityRequirement.restoreRequiredBytes(
            candidateBytes: validation.totalAssetBytes,
            currentLibraryBytes: currentLibraryBytes
        )
        let available = try capacity.availableBytes(at: parent)
        guard available >= required else {
            throw BackupError.insufficientSpace(required: required, available: available)
        }

        let operationID = UUID()
        let workspace = RestoreTransactionWorkspace.workspaceURL(operationID: operationID, parent: parent)
        let candidateRoot = workspace.appendingPathComponent(
            RestoreTransactionWorkspace.candidateDirectoryName,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            var transaction = try makeTransaction(validation: validation, operationID: operationID)
            try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)

            try await buildCandidate(
                packageURL: packageURL,
                validation: validation,
                candidateRoot: candidateRoot,
                progress: progress
            )

            transaction.phase = .prepared
            try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)

            // If the backup package lived inside the current library, keep a
            // copy inside the new library's backups directory so a successful
            // restore never deletes the user's backup.
            if packageURL.standardizedFileURL.path.hasPrefix(root.path + "/") {
                try preserveInternalBackup(packageURL: packageURL, candidateRoot: candidateRoot)
            }

            return BackupRestoreReadyInfo(
                backupID: validation.manifest.backupID,
                restoredRecordCounts: validation.manifest.recordCounts,
                restoredAssetCount: validation.manifest.assetCount,
                restoredAssetBytes: validation.totalAssetBytes,
                candidateCounts: validation.manifest.recordCounts
            )
        } catch {
            if FileManager.default.fileExists(atPath: workspace.path) {
                try? FileManager.default.removeItem(at: workspace)
            }
            throw error
        }
    }

    // MARK: Candidate Build

    private func buildCandidate(
        packageURL: URL,
        validation: BackupValidationResult,
        candidateRoot: URL,
        progress: @Sendable (BackupPhase) -> Void
    ) async throws {
        let candidateConfiguration = StorageConfiguration(rootURL: candidateRoot)
        let storage = try StorageService(configuration: candidateConfiguration)

        // Preserve the source library's logical identity.
        try await storage.writeLibraryManifest(StorageLibraryManifest(
            storageLayoutVersion: StorageConfiguration.layoutVersion,
            libraryID: validation.manifest.sourceLibraryID,
            createdAt: validation.manifest.sourceLibraryCreatedAt
        ))

        // Assets first (streaming copies, off the main actor).
        progress(.restoringAssets)
        let package = packageURL.standardizedFileURL
        for resourceID in validation.referencedAssets.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            guard let sourceURL = BackupPackageLayout.resolvedURL(
                in: package,
                relativePath: BackupPackageLayout.assetRelativePath(resourceID)
            ) else {
                throw BackupError.unsafePath(resourceID.rawValue)
            }
            let values = try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw BackupError.symbolicLink(sourceURL.lastPathComponent)
            }
            try await storage.importBackupAsset(from: sourceURL, to: resourceID)
        }

        // Metadata import in dependency order, then consistency validation.
        let candidateCounts = try await MainActor.run {
            progress(.restoringMetadata)
            let container = try WardrobeModelContainerFactory.production(
                databaseDirectory: candidateRoot.appendingPathComponent("database", isDirectory: true)
            )
            let importer = BackupMetadataImporter(container: container)
            let counts = try importer.importRecords(validation.records)
            let issues = try LibraryConsistencyValidator().validate(container: container)
            guard issues.isEmpty else {
                throw BackupError.candidateValidationFailed
            }
            try Self.verifyCandidateCounts(counts, expected: validation.manifest.recordCounts)
            return counts
        }
        _ = candidateCounts
        progress(.validating)

        // Every referenced asset must now resolve inside the candidate root.
        for resourceID in validation.referencedAssets {
            guard try await storage.exists(resourceID) else {
                throw BackupError.candidateValidationFailed
            }
        }
    }

    private func preserveInternalBackup(packageURL: URL, candidateRoot: URL) throws {
        let fileManager = FileManager.default
        let backupsDirectory = candidateRoot.appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let destination = backupsDirectory.appendingPathComponent(packageURL.lastPathComponent)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.copyItem(at: packageURL, to: destination)
    }

    private func makeTransaction(
        validation: BackupValidationResult,
        operationID: UUID
    ) throws -> RestoreTransaction {
        RestoreTransaction(
            operationID: operationID,
            phase: .prepared,
            backupID: validation.manifest.backupID,
            sourceLibraryID: validation.manifest.sourceLibraryID,
            sourceLibraryCreatedAt: validation.manifest.sourceLibraryCreatedAt,
            schemaVersion: validation.manifest.schemaVersion,
            storageLayoutVersion: validation.manifest.storageLayoutVersion,
            recordCounts: validation.manifest.recordCounts,
            assetCount: validation.manifest.assetCount,
            totalAssetBytes: validation.totalAssetBytes,
            createdAt: .now
        )
    }

    private static func verifyCandidateCounts(
        _ counts: BackupRecordCounts,
        expected: BackupRecordCounts
    ) throws {
        guard counts == expected else {
            throw BackupError.candidateValidationFailed
        }
    }
}

// MARK: - Bootstrap (apply at next launch, before opening the live library)

enum RestoreBootstrapOutcome: Equatable, Sendable {
    case none
    case completed(BackupRestoreResult)
    case rolledBack(BackupRestoreResult)
}

enum LibraryRestoreBootstrap {
    /// Runs before `StorageService`/`ModelContainer` open in the production
    /// composition root. Resolves any pending restore transaction with
    /// rollback protection; never opens an ambiguous half-restored library.
    @MainActor
    static func applyPendingRestore(
        configuration: StorageConfiguration,
        fileManager: FileManager = .default
    ) throws -> RestoreBootstrapOutcome {
        let root = configuration.rootURL.standardizedFileURL
        let parent = root.deletingLastPathComponent()
        guard let workspace = try RestoreTransactionWorkspace.discoverPending(parent: parent, fileManager: fileManager) else {
            return .none
        }
        guard var transaction = try RestoreTransactionWorkspace.readTransaction(in: workspace) else {
            throw BackupError.restoreInterrupted
        }
        try validateRootSafety(root, workspace: workspace, fileManager: fileManager)

        let rollbackURL = workspace.appendingPathComponent(RestoreTransactionWorkspace.rollbackDirectoryName, isDirectory: true)
        let candidateURL = workspace.appendingPathComponent(RestoreTransactionWorkspace.candidateDirectoryName, isDirectory: true)
        let failedURL = workspace.appendingPathComponent(RestoreTransactionWorkspace.failedDirectoryName, isDirectory: true)

        switch transaction.phase {
        case .committed:
            cleanupAfterCommit(workspace: workspace, rollbackURL: rollbackURL, fileManager: fileManager)
            return .none

        case .rollingBack, .rolledBack, .failed:
            return try finishRollback(
                transaction: &transaction,
                workspace: workspace,
                root: root,
                rollbackURL: rollbackURL,
                candidateURL: candidateURL,
                failedURL: failedURL,
                fileManager: fileManager
            )

        case .prepared, .originalMoved, .candidateInstalled, .verifying:
            break
        }

        do {
            // 1. Original library -> rollback sibling.
            if transaction.phase == .prepared {
                guard fileManager.fileExists(atPath: root.path) else {
                    throw BackupError.restoreInterrupted
                }
                try rename(root, to: rollbackURL, fileManager: fileManager)
                transaction.phase = .originalMoved
                try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)
            }
            guard fileManager.fileExists(atPath: rollbackURL.path) else {
                throw BackupError.restoreInterrupted
            }

            // 2. Candidate -> production root.
            if transaction.phase == .originalMoved {
                guard fileManager.fileExists(atPath: candidateURL.path) else {
                    throw BackupError.restoreInterrupted
                }
                try rename(candidateURL, to: root, fileManager: fileManager)
                transaction.phase = .candidateInstalled
                try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)
            }

            // 3. Verify the installed library before committing.
            transaction.phase = .verifying
            try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)
            try verifyInstalledLibrary(configuration: configuration, transaction: transaction)

            // 4. Commit and clean up.
            transaction.phase = .committed
            try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)
            let result = BackupRestoreResult(
                completedAt: .now,
                restoredRecordCounts: transaction.recordCounts,
                restoredAssetCount: transaction.assetCount,
                restoredAssetBytes: transaction.totalAssetBytes,
                rolledBack: false
            )
            try? RestoreResultMarker.write(result: result, parent: parent, fileManager: fileManager)
            cleanupAfterCommit(workspace: workspace, rollbackURL: rollbackURL, fileManager: fileManager)
            return .completed(result)
        } catch {
            // Any failure after the original was moved must restore it.
            return try finishRollback(
                transaction: &transaction,
                workspace: workspace,
                root: root,
                rollbackURL: rollbackURL,
                candidateURL: candidateURL,
                failedURL: failedURL,
                fileManager: fileManager
            )
        }
    }

    // MARK: Rollback

    private static func finishRollback(
        transaction: inout RestoreTransaction,
        workspace: URL,
        root: URL,
        rollbackURL: URL,
        candidateURL: URL,
        failedURL: URL,
        fileManager: FileManager
    ) throws -> RestoreBootstrapOutcome {
        do {
            let phaseBeforeRollback = transaction.phase
            transaction.phase = .rollingBack
            try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)

            // Quarantine an installed candidate that failed verification.
            if fileManager.fileExists(atPath: root.path), fileManager.fileExists(atPath: rollbackURL.path) {
                try rename(root, to: failedURL, fileManager: fileManager)
            }
            // Restore the original library if it is currently parked in rollback.
            let originalInRollback = fileManager.fileExists(atPath: rollbackURL.path)
            if originalInRollback, !fileManager.fileExists(atPath: root.path) {
                try rename(rollbackURL, to: root, fileManager: fileManager)
            }
            // The original was moved out of the root but its rollback snapshot
            // is gone and the candidate was never installed: the library is
            // unrecoverable, so startup must block instead of opening a
            // foreign or empty directory.
            if phaseBeforeRollback == .originalMoved, !originalInRollback {
                throw BackupError.restoreInterrupted
            }
            guard fileManager.fileExists(atPath: root.path) else {
                throw BackupError.restoreInterrupted
            }

            transaction.phase = .rolledBack
            try RestoreTransactionWorkspace.writeTransaction(transaction, in: workspace)
            let result = BackupRestoreResult(
                completedAt: .now,
                restoredRecordCounts: .zero,
                restoredAssetCount: 0,
                restoredAssetBytes: 0,
                rolledBack: true
            )
            try? RestoreResultMarker.write(result: result, parent: root.deletingLastPathComponent(), fileManager: fileManager)
            if fileManager.fileExists(atPath: workspace.path) {
                try? fileManager.removeItem(at: workspace)
            }
            return .rolledBack(result)
        } catch {
            throw BackupError.rollbackFailed
        }
    }

    private static func cleanupAfterCommit(
        workspace: URL,
        rollbackURL: URL,
        fileManager: FileManager
    ) {
        if fileManager.fileExists(atPath: rollbackURL.path) {
            try? fileManager.removeItem(at: rollbackURL)
        }
        if fileManager.fileExists(atPath: workspace.path) {
            try? fileManager.removeItem(at: workspace)
        }
    }

    // MARK: Verification

    @MainActor
    private static func verifyInstalledLibrary(
        configuration: StorageConfiguration,
        transaction: RestoreTransaction
    ) throws {
        guard FileManager.default.fileExists(atPath: configuration.rootURL.path) else {
            throw BackupError.candidateValidationFailed
        }
        guard StorageService.migrationPreflight(configuration: configuration) == .current else {
            throw BackupError.candidateValidationFailed
        }
        let container = try WardrobeModelContainerFactory.production(
            databaseDirectory: configuration.rootURL
                .appendingPathComponent("database", isDirectory: true)
        )
        let issues = try LibraryConsistencyValidator().validate(container: container)
        guard issues.isEmpty else {
            throw BackupError.candidateValidationFailed
        }
        let context = ModelContext(container)
        let counts = BackupRecordCounts(records: try readAllRecords(context: context))
        guard counts == transaction.recordCounts else {
            throw BackupError.candidateValidationFailed
        }
    }

    @MainActor
    private static func readAllRecords(context: ModelContext) throws -> BackupRecordsV1 {
        let exporter = SwiftDataBackupMetadataExporter(container: context.container)
        return try exporter.exportRecords()
    }

    // MARK: Safety

    private static func validateRootSafety(
        _ root: URL,
        workspace: URL,
        fileManager: FileManager
    ) throws {
        guard root.path != "/", root.path != fileManager.homeDirectoryForCurrentUser.path else {
            throw BackupError.restoreInterrupted
        }
        try BackupPackageStorage.validateNoSymbolicLink(at: root)
        try BackupPackageStorage.validateNoSymbolicLink(at: workspace)
        for name in [
            RestoreTransactionWorkspace.candidateDirectoryName,
            RestoreTransactionWorkspace.rollbackDirectoryName,
            RestoreTransactionWorkspace.failedDirectoryName,
        ] {
            let url = workspace.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                try BackupPackageStorage.validateNoSymbolicLink(at: url)
            }
        }
    }

    private static func rename(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw BackupError.restoreInterrupted
        }
        try BackupPackageStorage.validateNoSymbolicLink(at: source)
        try fileManager.moveItem(at: source, to: destination)
    }
}
