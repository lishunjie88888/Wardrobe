import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ExternalGenerationWorkspaceServing: Sendable {
    func publish(packageID: ExternalGenerationPackageID, files: [ExternalGenerationFile]) async throws -> URL
    func deletePackage(packageID: ExternalGenerationPackageID) async throws
}

@MainActor
protocol ClipboardServing: AnyObject {
    func copy(_ text: String) -> Bool
}

@MainActor
protocol ExternalAILaunching: AnyObject {
    func openChatGPT() -> Bool
    func revealInFinder(_ directoryURL: URL) -> Bool
}

protocol ExternalGenerationResultStorageServing: Sendable {
    func saveExternalGenerationResult(_ data: Data, mediaType: String, generationID: UUID) async throws -> StoredGenerationResources
    func deleteExternalGenerationResult(generationID: UUID) async throws
}

struct ExternalChatGPTPromptFormatter: Sendable {
    static let version = "wardrobe-external-chatgpt-prompt-v1"

    func format(attachments: [ExternalGenerationAttachment]) -> String {
        var lines = [
            "请根据以下按上传顺序编号的参考图，生成一张真实、自然的全身试穿照片：",
            "",
        ]
        for (index, attachment) in attachments.enumerated() {
            let description: String
            switch attachment.role {
            case .personPrimary: description = "人物主要身份参考"
            case .personReference: description = "人物辅助参考"
            case .garment: description = "\(attachment.slot?.externalDisplayName ?? "配饰")：\(attachment.displayName)"
            }
            lines.append("图\(index + 1)：\(description)")
        }
        lines += [
            "",
            "要求：",
            "- 保持人物身份、脸部特征、发型、人体比例与姿态尽可能一致。",
            "- 严格使用提供的实际衣物，保持颜色、图案、Logo/印花、材质与版型，不随意改动。",
            "- 不要无故增加未提供的衣物；配饰按参考素材使用。",
            "- 如有外套，明确表现外套与内搭的正确层次关系。",
            "- 完整显示全身，鞋子不得裁切，构图自然。",
            "- 输出写实照片，不要插画、卡通或服装设计稿。",
        ]
        return lines.joined(separator: "\n")
    }
}

struct ExternalGenerationPackageBuilder: Sendable {
    private let loader: any TryOnResourceLoading
    private let workspace: any ExternalGenerationWorkspaceServing
    private let formatter: ExternalChatGPTPromptFormatter
    private let now: @Sendable () -> Date

    init(
        loader: any TryOnResourceLoading,
        workspace: any ExternalGenerationWorkspaceServing,
        formatter: ExternalChatGPTPromptFormatter = ExternalChatGPTPromptFormatter(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.loader = loader
        self.workspace = workspace
        self.formatter = formatter
        self.now = now
    }

    func build(
        session: TryOnSession,
        person: PersonReferenceSet,
        clothing: [ClothingRecord],
        sourceGenerationID: UUID? = nil
    ) async throws -> ExternalGenerationPackage {
        guard let profileID = session.personProfileID, profileID == person.profileID else { throw ExternalGenerationError.noPerson }
        guard !session.selectedPersonImageIDs.isEmpty else { throw ExternalGenerationError.personHasNoReference }
        guard session.garmentCount > 0 else { throw ExternalGenerationError.noGarments }

        let references = [person.primaryImage].compactMap { $0 } + person.additionalImages
        let clothingByID = Dictionary(uniqueKeysWithValues: clothing.map { ($0.id, $0) })
        var attachments: [ExternalGenerationAttachment] = []
        var files: [ExternalGenerationFile] = []

        let selectedIDs = Set(session.selectedPersonImageIDs)
        let selectedReferences = references.filter { selectedIDs.contains($0.id) }
        guard selectedReferences.count == selectedIDs.count else { throw ExternalGenerationError.missingResource }
        var additionalIndex = 0
        for (index, image) in selectedReferences.enumerated() {
            let resource = image.processedResourceID ?? image.originalResourceID
            if !image.isPrimary { additionalIndex += 1 }
            let suffix = image.isPrimary ? "01-person-primary" : String(format: "%02d-person-reference-%02d", index + 1, additionalIndex)
            try await appendAttachment(
                id: image.id,
                baseName: suffix,
                role: image.isPrimary ? .personPrimary : .personReference,
                resource: resource,
                personImageID: image.id,
                clothingItemID: nil,
                slot: nil,
                sortOrder: index,
                displayName: index == 0 ? "人物主要参考" : "人物辅助参考",
                attachments: &attachments,
                files: &files
            )
        }

        for slot in TryOnSlot.allCases {
            for (sortOrder, clothingID) in session.garmentIDs(in: slot).enumerated() {
                guard let item = clothingByID[clothingID], !item.isArchived else { throw ExternalGenerationError.missingResource }
                let resource = item.processedResourceID ?? item.originalResourceID
                let baseName = slot.externalFileBaseName(sortOrder: sortOrder)
                try await appendAttachment(
                    id: item.id,
                    baseName: baseName,
                    role: .garment,
                    resource: resource,
                    personImageID: nil,
                    clothingItemID: item.id,
                    slot: slot,
                    sortOrder: sortOrder,
                    displayName: item.draft.name,
                    attachments: &attachments,
                    files: &files
                )
            }
        }

        let packageID = ExternalGenerationPackageID()
        let prompt = formatter.format(attachments: attachments)
        let manifest = ExternalGenerationManifest(
            schemaVersion: ExternalGenerationManifest.schemaVersion,
            workflowVersion: ExternalGenerationManifest.workflowVersion,
            packageID: packageID,
            createdAt: now(),
            personProfileID: profileID,
            sourceGenerationID: sourceGenerationID,
            attachments: attachments,
            prompt: prompt,
            source: .chatGPTManual
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        files.append(ExternalGenerationFile(name: "prompt.txt", data: Data(prompt.utf8)))
        files.append(ExternalGenerationFile(name: "manifest.json", data: try encoder.encode(manifest)))
        do {
            let directory = try await workspace.publish(packageID: packageID, files: files)
            return ExternalGenerationPackage(manifest: manifest, directoryURL: directory)
        } catch {
            throw ExternalGenerationError.packageCreationFailed
        }
    }

    private func appendAttachment(
        id: UUID,
        baseName: String,
        role: ExternalGenerationAttachmentRole,
        resource: StorageResourceID,
        personImageID: UUID?,
        clothingItemID: UUID?,
        slot: TryOnSlot?,
        sortOrder: Int,
        displayName: String,
        attachments: inout [ExternalGenerationAttachment],
        files: inout [ExternalGenerationFile]
    ) async throws {
        let data: Data
        do { data = try await loader.data(for: resource) }
        catch { throw ExternalGenerationError.missingResource }
        guard let fileExtension = ImageFileInspection.fileExtension(for: data) else { throw ExternalGenerationError.missingResource }
        let fileName = "\(baseName).\(fileExtension)"
        attachments.append(ExternalGenerationAttachment(
            id: id,
            fileName: fileName,
            role: role,
            resourceID: resource,
            personImageID: personImageID,
            clothingItemID: clothingItemID,
            slot: slot,
            sortOrder: sortOrder,
            displayName: displayName
        ))
        files.append(ExternalGenerationFile(name: fileName, data: data))
    }
}

@MainActor
final class ExternalGenerationWorkflow {
    struct PreparationResult: Equatable {
        let package: ExternalGenerationPackage
        let promptCopied: Bool
        let chatGPTOpened: Bool
        let finderOpened: Bool
    }

    private let builder: ExternalGenerationPackageBuilder
    private let clipboard: any ClipboardServing
    private let launcher: any ExternalAILaunching
    private let workspace: any ExternalGenerationWorkspaceServing

    init(builder: ExternalGenerationPackageBuilder, clipboard: any ClipboardServing, launcher: any ExternalAILaunching, workspace: any ExternalGenerationWorkspaceServing) {
        self.builder = builder
        self.clipboard = clipboard
        self.launcher = launcher
        self.workspace = workspace
    }

    func prepare(session: TryOnSession, person: PersonReferenceSet, clothing: [ClothingRecord], sourceGenerationID: UUID? = nil) async throws -> PreparationResult {
        let package = try await builder.build(session: session, person: person, clothing: clothing, sourceGenerationID: sourceGenerationID)
        return PreparationResult(
            package: package,
            promptCopied: clipboard.copy(package.manifest.prompt),
            chatGPTOpened: launcher.openChatGPT(),
            finderOpened: launcher.revealInFinder(package.directoryURL)
        )
    }

    func copyPrompt(from package: ExternalGenerationPackage) -> Bool { clipboard.copy(package.manifest.prompt) }
    func openChatGPT() -> Bool { launcher.openChatGPT() }
    func reveal(_ package: ExternalGenerationPackage) -> Bool { launcher.revealInFinder(package.directoryURL) }
    func delete(_ package: ExternalGenerationPackage) async throws { try await workspace.deletePackage(packageID: package.id) }
}

@MainActor
final class ExternalGenerationResultImporter {
    private let repository: any WardrobeRepository
    private let storage: any ExternalGenerationResultStorageServing

    init(repository: any WardrobeRepository, storage: any ExternalGenerationResultStorageServing) {
        self.repository = repository
        self.storage = storage
    }

    func importResult(from sourceURL: URL, package: ExternalGenerationPackage) async throws -> ImportedExternalGeneration {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let mediaType = ImageFileInspection.mediaType(for: data) else { throw ExternalGenerationError.invalidResultImage }
        let generationID = UUID()
        let resources: StoredGenerationResources
        do { resources = try await storage.saveExternalGenerationResult(data, mediaType: mediaType, generationID: generationID) }
        catch { throw ExternalGenerationError.resultStorageFailed }

        do {
            let record = GenerationRecord(
                id: generationID,
                sourceGenerationID: package.manifest.sourceGenerationID,
                providerID: "external-chatgpt-manual",
                statusCode: GenerationStatus.succeeded.rawValue,
                prompt: package.manifest.prompt,
                optionsJSON: "{\"packageID\":\"\(package.id.description)\",\"workflowVersion\":\"\(ExternalGenerationManifest.workflowVersion)\"}",
                resultResourceID: resources.result.rawValue,
                resultThumbnailResourceID: resources.thumbnail.rawValue,
                completedAt: .now
            )
            let profile = try repository.personProfile(id: package.manifest.personProfileID)
            for (index, attachment) in package.imageAttachments.filter({ $0.role != .garment }).enumerated() {
                guard let imageID = attachment.personImageID else { continue }
                record.personInputs.append(GenerationPersonInput(
                    generation: record,
                    personProfile: profile,
                    personProfileID: package.manifest.personProfileID,
                    personNameSnapshot: profile?.name ?? "已删除人物",
                    personImage: try repository.personImage(id: imageID),
                    personImageID: imageID,
                    resourceIDSnapshot: attachment.resourceID.rawValue,
                    sortOrder: index
                ))
            }
            for attachment in package.imageAttachments where attachment.role == .garment {
                guard let clothingID = attachment.clothingItemID, let slot = attachment.slot else { continue }
                let clothing = try repository.clothingItem(id: clothingID)
                record.garmentInputs.append(GenerationGarmentInput(
                    generation: record,
                    clothingItem: clothing,
                    clothingItemID: clothingID,
                    clothingNameSnapshot: attachment.displayName,
                    categoryCodeSnapshot: clothing?.categoryCode ?? ClothingCategory.other.rawValue,
                    slotCode: slot.rawValue,
                    resourceIDSnapshot: attachment.resourceID.rawValue,
                    sortOrder: attachment.sortOrder
                ))
            }
            try repository.insert(record)
            try repository.save()
            return ImportedExternalGeneration(generationID: generationID, resultResourceID: resources.result, thumbnailResourceID: resources.thumbnail, source: .chatGPTManual)
        } catch {
            try? await storage.deleteExternalGenerationResult(generationID: generationID)
            throw ExternalGenerationError.generationRecordFailed
        }
    }
}

private enum ImageFileInspection {
    static func fileExtension(for data: Data) -> String? {
        switch mediaType(for: data) {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/heic": "heic"
        case "image/heif": "heif"
        default: nil
        }
    }

    static func mediaType(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              type.conforms(to: .image)
        else { return nil }
        return type.preferredMIMEType
    }
}

private extension TryOnSlot {
    var externalDisplayName: String {
        switch self {
        case .upperBody: "上衣"
        case .outerwear: "外套"
        case .lowerBody: "下装"
        case .footwear: "鞋子"
        case .accessories: "配饰"
        }
    }

    func externalFileBaseName(sortOrder: Int) -> String {
        switch self {
        case .upperBody: "10-upper-body"
        case .outerwear: "20-outerwear"
        case .lowerBody: "30-lower-body"
        case .footwear: "40-footwear"
        case .accessories: String(format: "%02d-accessory-%02d", 50 + sortOrder, sortOrder + 1)
        }
    }
}
