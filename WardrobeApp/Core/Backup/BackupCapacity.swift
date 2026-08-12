import Foundation

/// Injectable capacity provider so disk-full conditions can be tested
/// deterministically without filling the disk.
protocol BackupCapacityChecking: Sendable {
    func availableBytes(at url: URL) throws -> Int64
}

struct SystemBackupCapacity: BackupCapacityChecking {
    func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

enum BackupCapacityRequirement {
    static let backupSafetyMargin: Int64 = 16 * 1_048_576
    static let restoreSafetyMargin: Int64 = 64 * 1_048_576

    /// Backup: the staging package plus an existing destination package that is
    /// being replaced, plus a safety margin.
    static func backupRequiredBytes(
        packageBytes: Int64,
        existingDestinationBytes: Int64
    ) -> Int64 {
        BackupSafeMath.add(
            BackupSafeMath.add(packageBytes, existingDestinationBytes),
            backupSafetyMargin
        )
    }

    /// Restore: the candidate bytes plus the current library bytes that form
    /// the rollback snapshot, plus a safety margin.
    static func restoreRequiredBytes(
        candidateBytes: Int64,
        currentLibraryBytes: Int64
    ) -> Int64 {
        BackupSafeMath.add(
            BackupSafeMath.add(candidateBytes, currentLibraryBytes),
            restoreSafetyMargin
        )
    }
}
