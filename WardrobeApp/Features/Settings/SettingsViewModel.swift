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
    @Published var showsPreview = false
    @Published var showsConfirmRestore = false

    let coordinator: BackupCoordinator

    init(coordinator: BackupCoordinator) {
        self.coordinator = coordinator
        self.restoreResult = coordinator.lastRestoreResult()
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
            preview = try await coordinator.preview(packageURL: url)
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
        await coordinator.prepareRestore(packageURL: url)
        readyInfo = coordinator.restoreReady
        restoreResult = nil
    }

    func quitApp() {
        NSApp.terminate(nil)
    }
}
