import Foundation

@MainActor
protocol GenerationHistoryPersisting {
    func generationHistory(matching query: GenerationHistoryQuery) throws -> [GenerationHistoryRecord]
    func generationDetail(id: UUID) throws -> GenerationDetailRecord?
    func deleteGeneration(id: UUID) throws
}

extension SwiftDataWardrobeRepository: GenerationHistoryPersisting {}

protocol GenerationHistoryImageLoading: Sendable {
    func data(for resourceID: StorageResourceID) async throws -> Data
}

protocol GenerationHistoryStorageServing: Sendable {
    func exists(_ resourceID: StorageResourceID) async throws -> Bool
    func delete(_ resourceID: StorageResourceID) async throws
}

extension StorageService: GenerationHistoryImageLoading, GenerationHistoryStorageServing {}

@MainActor
final class GenerationHistoryService {
    private let repository: any GenerationHistoryPersisting
    private let references: any ResourceReferenceInspecting
    private let storage: any GenerationHistoryStorageServing
    private let outfitService: OutfitService
    private let mapper = ClothingToTryOnSlotMapper()

    init(repository: any GenerationHistoryPersisting, references: any ResourceReferenceInspecting, storage: any GenerationHistoryStorageServing, outfitService: OutfitService) {
        self.repository = repository
        self.references = references
        self.storage = storage
        self.outfitService = outfitService
    }

    func history(matching query: GenerationHistoryQuery = GenerationHistoryQuery()) throws -> [GenerationHistoryRecord] {
        try repository.generationHistory(matching: query)
    }

    func detail(id: UUID) throws -> GenerationDetailRecord? { try repository.generationDetail(id: id) }

    func regeneratePreflight(id: UUID) async throws -> GenerationRegeneratePreflight {
        guard let detail = try repository.generationDetail(id: id) else { throw GenerationHistoryServiceError.notFound }
        guard detail.status.isTerminal else { throw GenerationHistoryServiceError.nonterminalRecord }
        var unavailable: [GenerationUnavailableInput] = []
        for person in detail.persons {
            let reason: GenerationUnavailableReason?
            if !person.hasCurrentProfile || !person.hasCurrentImage { reason = .missing }
            else if !person.currentProfileIsActive { reason = .archived }
            else if !(await resourceExists(person.resourceIDSnapshot)) { reason = .missingResource }
            else { reason = nil }
            if let reason { unavailable.append(.init(id: person.id, name: person.personNameSnapshot, reason: reason)) }
        }
        var garments: [OutfitLoadItem] = []
        for item in detail.garments {
            let reason = await garmentUnavailableReason(item, requireResource: true)
            if let reason { unavailable.append(.init(id: item.id, name: item.clothingNameSnapshot, reason: reason)) }
            else if let slot = item.resolvedSlot {
                garments.append(.init(id: item.id, clothingItemID: item.clothingItemID, slot: slot, sortOrder: item.sortOrder))
            }
        }
        let profileIDs = Set(detail.persons.map(\.personProfileID))
        let request: GenerationRegenerateRequest? = unavailable.isEmpty && profileIDs.count == 1 && !detail.persons.isEmpty && !garments.isEmpty
            ? .init(sourceGenerationID: detail.id, personProfileID: profileIDs.first!, selectedPersonImageIDs: detail.persons.map(\.personImageID), garments: garments, historicalPrompt: detail.prompt, historicalOptionsText: detail.optionsText)
            : nil
        return .init(request: request, unavailableInputs: unavailable)
    }

    func saveOutfitPreflight(id: UUID) async throws -> GenerationSaveOutfitPreflight {
        guard let detail = try repository.generationDetail(id: id) else { throw GenerationHistoryServiceError.notFound }
        guard detail.status == .known(.succeeded) else { throw GenerationHistoryServiceError.saveOutfitUnavailable }
        var items: [OutfitCreationItem] = []
        var unavailable: [GenerationUnavailableInput] = []
        for item in detail.garments {
            if let reason = await garmentUnavailableReason(item, requireResource: false) {
                unavailable.append(.init(id: item.id, name: item.clothingNameSnapshot, reason: reason))
            } else {
                items.append(.init(clothingItemID: item.clothingItemID, slotCode: item.slotCode, sortOrder: item.sortOrder))
            }
        }
        return .init(items: items, unavailableInputs: unavailable)
    }

    func saveAsOutfit(id: UUID, draft: OutfitDraft, at date: Date = .now) async throws -> OutfitRecord {
        let preflight = try await saveOutfitPreflight(id: id)
        guard preflight.canSave else { throw GenerationHistoryServiceError.saveOutfitUnavailable }
        return try outfitService.create(draft: draft, items: preflight.items, at: date)
    }

    func deleteImpact(id: UUID) throws -> GenerationDeleteImpact {
        guard let detail = try repository.generationDetail(id: id) else { throw GenerationHistoryServiceError.notFound }
        let candidates = [detail.resultResourceID, detail.resultThumbnailResourceID].compactMap { resource -> StorageResourceID? in
            guard let resource, resource.owner.kind == .generation, resource.owner.id == id else { return nil }
            return resource
        }
        return .init(generationID: id, personInputCount: detail.persons.count, garmentInputCount: detail.garments.count, resultCleanupCandidateCount: Set(candidates).count, canDelete: detail.status.isTerminal)
    }

    func permanentlyDelete(id: UUID) async throws -> GenerationDeleteResult {
        guard let detail = try repository.generationDetail(id: id) else { throw GenerationHistoryServiceError.notFound }
        guard detail.status.isTerminal else { throw GenerationHistoryServiceError.nonterminalRecord }
        let candidates = Set([detail.resultResourceID, detail.resultThumbnailResourceID].compactMap { resource -> StorageResourceID? in
            guard let resource, resource.owner.kind == .generation, resource.owner.id == id else { return nil }
            return resource
        })
        try repository.deleteGeneration(id: id)
        let stillReferenced = try references.referencedResources(in: candidates)
        var issues = 0
        for resource in candidates.subtracting(stillReferenced) {
            do { if try await storage.exists(resource) { try await storage.delete(resource) } }
            catch { issues += 1 }
        }
        return .init(cleanupIssueCount: issues)
    }

    private func resourceExists(_ resource: StorageResourceID?) async -> Bool {
        guard let resource else { return false }
        return (try? await storage.exists(resource)) == true
    }

    private func garmentUnavailableReason(_ item: GenerationGarmentSnapshotRecord, requireResource: Bool) async -> GenerationUnavailableReason? {
        guard item.hasCurrentClothing else { return .missing }
        guard item.currentClothingIsActive else { return .archived }
        guard let slot = item.resolvedSlot else { return .invalidSlot }
        guard case let .supported(mapped) = mapper.slot(for: item.currentCategoryCode ?? ""), mapped == slot else { return .incompatible }
        if requireResource, !(await resourceExists(item.resourceIDSnapshot)) { return .missingResource }
        return nil
    }
}

enum GenerationHistoryRedactor {
    private static let sensitiveKeys = ["authorization", "apikey", "api_key", "token", "cookie", "secret", "password"]

    static func options(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            return redactText(raw)
        }
        let redacted = redactJSON(object)
        guard JSONSerialization.isValidJSONObject(redacted),
              let output = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys])
        else { return redactText(raw) }
        return String(decoding: output, as: UTF8.self)
    }

    static func errorMessage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var safe = redactText(raw)
        safe = safe.replacingOccurrences(of: #"(?:/Users|/Volumes|/private|/var|/tmp)/[^\s]+"#, with: "[路径已隐藏]", options: .regularExpression)
        return safe
    }

    private static func redactJSON(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                (key, isSensitive(key) ? "***" : redactJSON(value))
            })
        }
        if let array = value as? [Any] { return array.map(redactJSON) }
        return value
    }

    private static func redactText(_ raw: String) -> String {
        var value = raw
        for key in sensitiveKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            value = value.replacingOccurrences(of: #"(?i)(\"?\#(escaped)\"?\s*[:=]\s*\"?)[^\",\s}]+"#, with: "$1***", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#, with: "Bearer ***", options: .regularExpression)
        return value
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return sensitiveKeys.contains { normalized == $0.lowercased() }
    }
}
