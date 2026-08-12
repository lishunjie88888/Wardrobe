import AppKit
import Foundation
import SwiftData
import SwiftUI

/// MainActor-facing facade for backup/restore. Heavy file work stays inside
/// the Core actors; this type only forwards progress, summaries and safe
/// errors to the UI.
@MainActor
final class BackupCoordinator: ObservableObject {
    @Published private(set) var phase: BackupPhase?
    @Published private(set) var lastBackupSummary: BackupSummary?
    @Published private(set) var lastError: BackupError?
    @Published private(set) var restoreReady: BackupRestoreReadyInfo?
    @Published private(set) var isBusy = false

    private let exporter: BackupExporter
    private let restoreCoordinator: LibraryRestoreCoordinator
    private let configuration: StorageConfiguration

    init(
        container: ModelContainer,
        storageService: StorageService,
        configuration: StorageConfiguration,
        capacity: any BackupCapacityChecking = SystemBackupCapacity()
    ) {
        self.configuration = configuration
        let metadataExporter = SwiftDataBackupMetadataExporter(container: container)
        self.exporter = BackupExporter(
            configuration: configuration,
            metadataExporter: metadataExporter,
            assetReader: storageService,
            capacity: capacity
        )
        self.restoreCoordinator = LibraryRestoreCoordinator(
            configuration: configuration,
            capacity: capacity
        )
    }

    var isPendingRestorePresent: Bool {
        let parent = configuration.rootURL.standardizedFileURL.deletingLastPathComponent()
        return (try? RestoreTransactionWorkspace.discoverPending(parent: parent)) != nil
    }

    func createBackup(destination: URL) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        lastBackupSummary = nil
        defer { isBusy = false }
        do {
            guard !isPendingRestorePresent else { throw BackupError.pendingRestoreExists }
            let summary = try await exporter.createBackup(destination: destination) { [weak self] phase in
                Task { @MainActor in self?.phase = phase }
            }
            lastBackupSummary = summary
        } catch is CancellationError {
            lastError = .cancelled
        } catch let error as BackupError {
            lastError = error
        } catch {
            lastError = Self.mapStorageError(error)
        }
        phase = nil
    }

    func preview(packageURL: URL) async throws -> BackupPreview {
        let validation = try BackupValidator().validate(packageURL: packageURL)
        return BackupPreview(
            backupID: validation.manifest.backupID,
            createdAt: validation.manifest.createdAt,
            backupFormatVersion: validation.manifest.backupFormatVersion,
            schemaVersion: validation.manifest.schemaVersion,
            storageLayoutVersion: validation.manifest.storageLayoutVersion,
            recordCounts: validation.manifest.recordCounts,
            assetCount: validation.manifest.assetCount,
            totalAssetBytes: validation.totalAssetBytes,
            sourceLibraryID: validation.manifest.sourceLibraryID,
            validationStatus: .valid
        )
    }

    func prepareRestore(packageURL: URL) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        restoreReady = nil
        defer { isBusy = false }
        do {
            let ready = try await restoreCoordinator.prepare(packageURL: packageURL) { [weak self] phase in
                Task { @MainActor in self?.phase = phase }
            }
            restoreReady = ready
        } catch is CancellationError {
            lastError = .cancelled
        } catch let error as BackupError {
            lastError = error
        } catch {
            lastError = Self.mapStorageError(error)
        }
        phase = nil
    }

    func lastRestoreResult() -> BackupRestoreResult? {
        let parent = configuration.rootURL.standardizedFileURL.deletingLastPathComponent()
        return RestoreResultMarker.read(parent: parent)
    }

    private static func mapStorageError(_ error: Error) -> BackupError {
        if let storageError = error as? StorageError {
            switch storageError {
            case let .resourceNotFound(id):
                return .missingAsset(resource: id.rawValue)
            case .migrationBlocked, .invalidLibraryManifest, .unsupportedLayoutVersion:
                return .libraryUnavailable
            default:
                return .destinationUnavailable
            }
        }
        return .destinationUnavailable
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var preview: BackupPreview?
    @Published private(set) var selectedPackageURL: URL?
    @Published private(set) var readyInfo: BackupRestoreReadyInfo?
    @Published private(set) var restoreResult: BackupRestoreResult?
    @Published private(set) var previewError: BackupError?
    @Published private(set) var cacheUsageBytes: Int64?
    @Published private(set) var cacheCleanupResult: CacheCleanupResult?
    @Published private(set) var orphanReport: OrphanReport?
    @Published private(set) var orphanCleanupResult: OrphanCleanupResult?
    @Published private(set) var maintenanceMessage: String?
    @Published private(set) var isMaintenanceBusy = false
    @Published var showsPreview = false
    @Published var showsConfirmRestore = false
    @Published var showsOrphanCleanupConfirmation = false

    let coordinator: BackupCoordinator
    private let storageService: StorageService
    private let orphanReportService: OrphanReportService

    init(
        coordinator: BackupCoordinator,
        storageService: StorageService,
        orphanReportService: OrphanReportService
    ) {
        self.coordinator = coordinator
        self.storageService = storageService
        self.orphanReportService = orphanReportService
        self.restoreResult = coordinator.lastRestoreResult()
    }

    func loadStorageDiagnostics() async {
        cacheUsageBytes = try? await storageService.cacheStorageSize()
        orphanReport = try? await orphanReportService.generateReport()
    }

    func enforceCacheLimit() async {
        guard !isMaintenanceBusy else { return }
        isMaintenanceBusy = true
        defer { isMaintenanceBusy = false }
        do {
            let result = try await storageService.enforceCacheLimit()
            cacheCleanupResult = result
            cacheUsageBytes = try? await storageService.cacheStorageSize()
            maintenanceMessage = result.removedFileCount == 0
                ? "缓存未超过上限，无需清理。"
                : "已清理 \(result.removedFileCount) 个缓存文件（\(ByteCountFormatter.string(fromByteCount: result.removedBytes, countStyle: .file))）。"
        } catch {
            maintenanceMessage = "缓存清理失败：\(error.localizedDescription)"
        }
    }

    func generateOrphanReport() async {
        guard !isMaintenanceBusy else { return }
        isMaintenanceBusy = true
        defer { isMaintenanceBusy = false }
        do {
            orphanReport = try await orphanReportService.generateReport()
            maintenanceMessage = "扫描完成。孤儿文件仅报告，默认不删除。"
        } catch {
            maintenanceMessage = "扫描失败：\(error.localizedDescription)"
        }
    }

    func requestOrphanCleanup() {
        showsOrphanCleanupConfirmation = true
    }

    func confirmOrphanCleanup() async {
        showsOrphanCleanupConfirmation = false
        guard !isMaintenanceBusy else { return }
        isMaintenanceBusy = true
        defer { isMaintenanceBusy = false }
        do {
            let result = try await orphanReportService.deleteEligibleUnreferenced()
            orphanCleanupResult = result
            orphanReport = try? await orphanReportService.generateReport()
            cacheUsageBytes = try? await storageService.cacheStorageSize()
            maintenanceMessage = result.deletedResources.isEmpty
                ? "没有符合条件的文件被删除。"
                : "已删除 \(result.deletedResources.count) 个无引用文件；\(result.retainedResources.count) 个文件因仍被引用而保留。"
        } catch {
            maintenanceMessage = "清理失败：\(error.localizedDescription)"
        }
    }

    func chooseBackupDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "创建备份"
        panel.prompt = "创建备份"
        panel.nameFieldStringValue = "Wardrobe 备份.\(BackupFormat.packageExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let path = url.path
        if path.hasSuffix(".\(BackupFormat.packageExtension)") { return url }
        return url.appendingPathExtension(BackupFormat.packageExtension)
    }

    func chooseBackupPackage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择备份"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    func createBackup(to url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        await coordinator.createBackup(destination: url)
        if coordinator.lastBackupSummary != nil {
            preview = nil
            selectedPackageURL = nil
            readyInfo = nil
        }
    }

    func validateSelectedPackage(_ url: URL) async {
        preview = nil
        previewError = nil
        selectedPackageURL = url
        do {
            preview = try await withSecurityScopedAccess(to: url) {
                try await coordinator.preview(packageURL: url)
            }
            showsPreview = true
        } catch let error as BackupError {
            previewError = error
            showsPreview = true
        } catch {
            previewError = .invalidManifest
            showsPreview = true
        }
    }

    func confirmRestore() async {
        guard let url = selectedPackageURL else { return }
        showsConfirmRestore = false
        showsPreview = false
        await withSecurityScopedAccess(to: url) {
            await coordinator.prepareRestore(packageURL: url)
        }
        readyInfo = coordinator.restoreReady
        restoreResult = nil
    }

    private func withSecurityScopedAccess<T>(to url: URL, _ operation: () async throws -> T) async rethrows -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try await operation()
    }

    func quitApp() {
        NSApp.terminate(nil)
    }
}
