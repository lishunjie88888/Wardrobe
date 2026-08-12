import Foundation
import SwiftData

// MARK: - Format Version

enum BackupFormat {
    static let version = 1
    static let packageExtension = "wardrobebackup"
    static let allowedExtraFiles: Set<String> = [".DS_Store"]
}

// MARK: - Errors

enum BackupError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedBackupFormat(found: Int)
    case unsupportedSchemaVersion(String)
    case unsupportedStorageLayout(Int)
    case invalidManifest
    case invalidRecords
    case invalidChecksumManifest
    case checksumMismatch(path: String)
    case missingAsset(resource: String)
    case unsafePath(String)
    case symbolicLink(String)
    case duplicateRecordID(entity: String, id: UUID)
    case brokenRelationship(entity: String, id: UUID)
    case invalidResourceID(resource: String, recordID: UUID?)
    case insufficientSpace(required: Int64, available: Int64)
    case libraryChangedDuringBackup
    case candidateValidationFailed
    case restoreInterrupted
    case rollbackFailed
    case pendingRestoreExists
    case nonterminalGeneration
    case destinationUnavailable
    case libraryUnavailable
    case notADirectory
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unsupportedBackupFormat(found):
            "备份格式版本 \(found) 不受支持。"
        case let .unsupportedSchemaVersion(version):
            "备份的数据结构版本 \(version) 不受支持。"
        case let .unsupportedStorageLayout(layout):
            "备份的存储布局版本 \(layout) 不受支持。"
        case .invalidManifest:
            "备份的清单文件无效。"
        case .invalidRecords:
            "备份的记录文件无效。"
        case .invalidChecksumManifest:
            "备份的校验和清单无效。"
        case let .checksumMismatch(path):
            "备份文件 \(path) 校验和不一致，备份可能已损坏。"
        case .missingAsset:
            "资料库引用的部分文件缺失，无法创建完整备份。"
        case .unsafePath:
            "备份包含不安全的路径。"
        case .symbolicLink:
            "备份包含符号链接，已拒绝恢复。"
        case let .duplicateRecordID(entity, _):
            "备份包含重复的记录标识（\(entity)）。"
        case let .brokenRelationship(entity, _):
            "备份包含无效的关系引用（\(entity)）。"
        case .invalidResourceID:
            "备份包含无效的资源标识。"
        case let .insufficientSpace(required, available):
            "磁盘空间不足：需要约 \(Self.bytes(required))，可用 \(Self.bytes(available))。"
        case .libraryChangedDuringBackup:
            "备份过程中资料库发生变化，已中止本次备份，请重试。"
        case .candidateValidationFailed:
            "恢复出的资料库未通过一致性验证。"
        case .restoreInterrupted:
            "恢复未完成，且无法安全继续。Wardrobe 已停止打开资料库以保护数据。"
        case .rollbackFailed:
            "恢复未完成，且自动回滚无法验证。Wardrobe 已停止打开资料库以保护数据。"
        case .pendingRestoreExists:
            "已存在等待完成的恢复事务，请先重启完成恢复。"
        case .nonterminalGeneration:
            "有生成任务尚未结束，请完成或取消后重试。"
        case .destinationUnavailable:
            "目标位置不可写，无法创建备份。"
        case .libraryUnavailable:
            "资料库当前无法安全备份（可能正在进行迁移或已损坏）。"
        case .notADirectory:
            "选择的备份包不是有效目录。"
        case .cancelled:
            "操作已取消。"
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - Manifest

struct BackupRecordCounts: Codable, Equatable, Sendable {
    var clothingItems: Int
    var personProfiles: Int
    var personImages: Int
    var outfits: Int
    var outfitItems: Int
    var generations: Int
    var generationPersonInputs: Int
    var generationGarmentInputs: Int

    static let zero = BackupRecordCounts(
        clothingItems: 0, personProfiles: 0, personImages: 0,
        outfits: 0, outfitItems: 0, generations: 0,
        generationPersonInputs: 0, generationGarmentInputs: 0
    )

    init(records: BackupRecordsV1) {
        self.init(
            clothingItems: records.clothingItems.count,
            personProfiles: records.personProfiles.count,
            personImages: records.personImages.count,
            outfits: records.outfits.count,
            outfitItems: records.outfitItems.count,
            generations: records.generations.count,
            generationPersonInputs: records.generationPersonInputs.count,
            generationGarmentInputs: records.generationGarmentInputs.count
        )
    }

    init(
        clothingItems: Int, personProfiles: Int, personImages: Int,
        outfits: Int, outfitItems: Int, generations: Int,
        generationPersonInputs: Int, generationGarmentInputs: Int
    ) {
        self.clothingItems = clothingItems
        self.personProfiles = personProfiles
        self.personImages = personImages
        self.outfits = outfits
        self.outfitItems = outfitItems
        self.generations = generations
        self.generationPersonInputs = generationPersonInputs
        self.generationGarmentInputs = generationGarmentInputs
    }

    var isEmpty: Bool {
        self == .zero
    }
}

struct BackupManifest: Codable, Equatable, Sendable {
    var backupFormatVersion: Int
    var backupID: UUID
    var createdAt: Date
    var applicationVersion: String
    var applicationBuild: String
    var sourceLibraryID: UUID
    var sourceLibraryCreatedAt: Date
    var schemaVersion: String
    var storageLayoutVersion: Int
    var recordCounts: BackupRecordCounts
    var assetCount: Int
    var totalAssetBytes: Int64
}

// MARK: - Logical Records (independent wire format; not SwiftData models)

struct BackupRecordsV1: Codable, Equatable, Sendable {
    var clothingItems: [BackupClothingRecordV1]
    var personProfiles: [BackupPersonProfileV1]
    var personImages: [BackupPersonImageV1]
    var outfits: [BackupOutfitV1]
    var outfitItems: [BackupOutfitItemV1]
    var generations: [BackupGenerationRecordV1]
    var generationPersonInputs: [BackupGenerationPersonInputV1]
    var generationGarmentInputs: [BackupGenerationGarmentInputV1]

    init(
        clothingItems: [BackupClothingRecordV1] = [],
        personProfiles: [BackupPersonProfileV1] = [],
        personImages: [BackupPersonImageV1] = [],
        outfits: [BackupOutfitV1] = [],
        outfitItems: [BackupOutfitItemV1] = [],
        generations: [BackupGenerationRecordV1] = [],
        generationPersonInputs: [BackupGenerationPersonInputV1] = [],
        generationGarmentInputs: [BackupGenerationGarmentInputV1] = []
    ) {
        self.clothingItems = clothingItems
        self.personProfiles = personProfiles
        self.personImages = personImages
        self.outfits = outfits
        self.outfitItems = outfitItems
        self.generations = generations
        self.generationPersonInputs = generationPersonInputs
        self.generationGarmentInputs = generationGarmentInputs
    }
}

struct BackupClothingRecordV1: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var notes: String?
    var categoryCode: String
    var subcategoryCode: String?
    var brand: String?
    var colorCodes: [String]
    var seasonCodes: [String]
    var styleCodes: [String]
    var materials: [String]
    var tags: [String]
    var isFavorite: Bool
    var originalResourceID: String
    var processedResourceID: String?
    var thumbnailResourceID: String?
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct BackupPersonProfileV1: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var notes: String?
    var isDefault: Bool
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct BackupPersonImageV1: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var profileID: UUID
    var isPrimary: Bool
    var originalResourceID: String
    var processedResourceID: String?
    var thumbnailResourceID: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var createdAt: Date
    var updatedAt: Date
}

struct BackupOutfitV1: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var notes: String?
    var isFavorite: Bool
    var coverResourceID: String?
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct BackupOutfitItemV1: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var outfitID: UUID
    var clothingItemID: UUID
    var clothingItemRelationID: UUID?
    var clothingNameSnapshot: String
    var thumbnailResourceIDSnapshot: String?
    var slotCode: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

struct BackupGenerationRecordV1: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var sourceGenerationID: UUID?
    var providerID: String
    var providerModelID: String?
    var statusCode: String
    var prompt: String
    var optionsJSON: String
    var providerRequestID: String?
    var resultResourceID: String?
    var resultThumbnailResourceID: String?
    var errorCode: String?
    var errorMessage: String?
    var attemptCount: Int
    var startedAt: Date?
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct BackupGenerationPersonInputV1: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var generationID: UUID
    var personProfileID: UUID
    var personProfileRelationID: UUID?
    var personNameSnapshot: String
    var personImageID: UUID
    var personImageRelationID: UUID?
    var resourceIDSnapshot: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

struct BackupGenerationGarmentInputV1: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var generationID: UUID
    var clothingItemID: UUID
    var clothingItemRelationID: UUID?
    var clothingNameSnapshot: String
    var categoryCodeSnapshot: String
    var slotCode: String
    var resourceIDSnapshot: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - Checksums

struct BackupChecksumEntry: Codable, Equatable, Sendable, Comparable {
    let relativePath: String
    let byteCount: Int64
    let sha256: String

    static func < (left: BackupChecksumEntry, right: BackupChecksumEntry) -> Bool {
        left.relativePath < right.relativePath
    }
}

struct BackupChecksumManifest: Codable, Equatable, Sendable {
    var entries: [BackupChecksumEntry]

    init(entries: [BackupChecksumEntry]) {
        self.entries = entries.sorted()
    }
}

struct BackupFileDigest: Equatable, Sendable {
    let byteCount: Int64
    let sha256: String
}

// MARK: - Phases, Summary, Preview

enum BackupPhase: String, Sendable, CaseIterable {
    case preparing
    case exportingMetadata
    case copyingAssets
    case verifying
    case publishing
    case preparingRestore
    case restoringMetadata
    case restoringAssets
    case validating
    case readyToRestart

    var title: String {
        switch self {
        case .preparing: "准备中"
        case .exportingMetadata: "正在导出资料"
        case .copyingAssets: "正在复制文件"
        case .verifying: "正在验证"
        case .publishing: "正在发布"
        case .preparingRestore: "正在准备恢复"
        case .restoringMetadata: "正在恢复资料"
        case .restoringAssets: "正在恢复文件"
        case .validating: "正在验证恢复结果"
        case .readyToRestart: "已准备好，请重新启动"
        }
    }
}

struct BackupSummary: Equatable, Sendable {
    let backupID: UUID
    let createdAt: Date
    let recordCounts: BackupRecordCounts
    let assetCount: Int
    let totalAssetBytes: Int64
    let formatVersion: Int
    let schemaVersion: String
    let storageLayoutVersion: Int
    let unreferencedFileCount: Int
}

struct BackupPreview: Equatable, Sendable {
    let backupID: UUID
    let createdAt: Date
    let backupFormatVersion: Int
    let schemaVersion: String
    let storageLayoutVersion: Int
    let recordCounts: BackupRecordCounts
    let assetCount: Int
    let totalAssetBytes: Int64
    let sourceLibraryID: UUID
    let validationStatus: BackupValidationStatus
}

enum BackupValidationStatus: Equatable, Sendable {
    case valid
    case blocked(reason: String)
}

struct BackupRestoreReadyInfo: Equatable, Sendable {
    let backupID: UUID
    let restoredRecordCounts: BackupRecordCounts
    let restoredAssetCount: Int
    let restoredAssetBytes: Int64
    let candidateCounts: BackupRecordCounts
}

struct BackupRestoreResult: Equatable, Sendable {
    let completedAt: Date
    let restoredRecordCounts: BackupRecordCounts
    let restoredAssetCount: Int
    let restoredAssetBytes: Int64
    let rolledBack: Bool
}

// MARK: - Version Helpers

enum BackupVersion {
    static func string(schemaVersion: Schema.Version) -> String {
        "\(schemaVersion.major).\(schemaVersion.minor).\(schemaVersion.patch)"
    }

    static func schemaVersion(from string: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    static func isCurrentSchema(_ string: String) -> Bool {
        guard let version = schemaVersion(from: string) else { return false }
        return version.major == WardrobeSchemaV1.versionIdentifier.major
            && version.minor == WardrobeSchemaV1.versionIdentifier.minor
            && version.patch == WardrobeSchemaV1.versionIdentifier.patch
    }
}
