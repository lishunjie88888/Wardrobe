import Foundation

struct ExternalGenerationPackageID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    var description: String { rawValue.uuidString.lowercased() }
}

enum ExternalGenerationSource: String, Codable, Sendable {
    case chatGPTManual = "chatgpt-manual"
}

enum ExternalGenerationAttachmentRole: String, Codable, Sendable {
    case personPrimary = "person-primary"
    case personReference = "person-reference"
    case garment = "garment"
}

struct ExternalGenerationAttachment: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let fileName: String
    let role: ExternalGenerationAttachmentRole
    let resourceID: StorageResourceID
    let personImageID: UUID?
    let clothingItemID: UUID?
    let slot: TryOnSlot?
    let sortOrder: Int
    let displayName: String
}

struct ExternalGenerationManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let workflowVersion = "wardrobe-external-chatgpt-v1"

    let schemaVersion: Int
    let workflowVersion: String
    let packageID: ExternalGenerationPackageID
    let createdAt: Date
    let personProfileID: UUID
    let attachments: [ExternalGenerationAttachment]
    let prompt: String
    let source: ExternalGenerationSource
}

struct ExternalGenerationPackage: Equatable, Sendable, Identifiable {
    var id: ExternalGenerationPackageID { manifest.packageID }
    let manifest: ExternalGenerationManifest
    /// A transient, launcher-only location. It is intentionally excluded from the manifest and persistence.
    let directoryURL: URL

    var imageAttachments: [ExternalGenerationAttachment] { manifest.attachments }
    var personAttachmentCount: Int { imageAttachments.filter { $0.role != .garment }.count }
    var garmentAttachmentCount: Int { imageAttachments.filter { $0.role == .garment }.count }
}

struct ExternalGenerationFile: Sendable {
    let name: String
    let data: Data
}

struct ImportedExternalGeneration: Equatable, Sendable {
    let generationID: UUID
    let resultResourceID: StorageResourceID
    let thumbnailResourceID: StorageResourceID
    let source: ExternalGenerationSource
}

enum ExternalGenerationError: Error, Equatable, Sendable {
    case noPerson
    case personHasNoReference
    case noGarments
    case missingResource
    case invalidResultImage
    case packageCreationFailed
    case clipboardFailed
    case chatGPTLaunchFailed
    case finderRevealFailed
    case resultStorageFailed
    case generationRecordFailed
}
