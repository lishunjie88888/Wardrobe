import Foundation

enum VirtualTryOnServiceError: Error, Equatable, Sendable {
    case recordCreationFailed
    case preparationFailed
    case provider(VirtualTryOnError)
    case resultStorageFailed
    case recordUpdateFailed
}

struct PersistedTryOnGeneration: Equatable, Sendable {
    let generationID: UUID
    let resultResourceID: StorageResourceID
    let thumbnailResourceID: StorageResourceID
    let providerName: String
    let personName: String
    let garmentsBySlot: [TryOnSlot: [String]]
}

@MainActor
final class VirtualTryOnService {
    private let repository: any WardrobeRepository
    private let storage: any ExternalGenerationResultStorageServing
    private let requestBuilder: VirtualTryOnRequestBuilder
    private let provider: any VirtualTryOnProvider
    private let maximumAttempts: Int
    private let now: @Sendable () -> Date

    init(
        repository: any WardrobeRepository,
        storage: any ExternalGenerationResultStorageServing,
        requestBuilder: VirtualTryOnRequestBuilder,
        provider: any VirtualTryOnProvider,
        maximumAttempts: Int = 2,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.repository = repository
        self.storage = storage
        self.requestBuilder = requestBuilder
        self.provider = provider
        self.maximumAttempts = max(1, maximumAttempts)
        self.now = now
    }

    func generate(
        session: TryOnSession,
        person: PersonReferenceSet,
        personName: String,
        clothing: [ClothingRecord],
        options: TryOnOptions = TryOnOptions(),
        sourceGenerationID: UUID? = nil
    ) async throws -> PersistedTryOnGeneration {
        let generationID = UUID()
        let record = GenerationRecord(
            id: generationID,
            sourceGenerationID: sourceGenerationID,
            providerID: provider.descriptor.id.rawValue,
            optionsJSON: Self.optionsJSON(options)
        )

        do {
            try populateSnapshots(record, session: session, person: person, personName: personName, clothing: clothing)
            try repository.insert(record)
            try repository.save()
        } catch {
            throw VirtualTryOnServiceError.recordCreationFailed
        }

        do {
            try repository.transitionGeneration(id: generationID, to: .preparing, at: now())
            let request = try await requestBuilder.build(
                session: session,
                person: person,
                clothing: clothing,
                capabilities: provider.capabilities,
                options: options
            )
            record.prompt = request.prompt
            record.optionsJSON = Self.optionsJSON(request.options)
            record.markUpdated(at: now())
            try repository.save()
            try Task.checkCancellation()
            try await provider.validateConfiguration()
            record.startedAt = now()
            try repository.transitionGeneration(id: generationID, to: .running, at: now())

            let result = try await callProvider(request: request, record: record)
            try Task.checkCancellation()
            let resources: StoredGenerationResources
            do {
                resources = try await storage.saveExternalGenerationResult(
                    result.imageData,
                    mediaType: result.mediaType,
                    generationID: generationID
                )
            } catch {
                throw VirtualTryOnServiceError.resultStorageFailed
            }
            do {
                try Task.checkCancellation()
                record.providerRequestID = result.providerRequestID
                record.providerModelID = result.providerModelID
                record.resultResourceID = resources.result.rawValue
                record.resultThumbnailResourceID = resources.thumbnail.rawValue
                record.completedAt = now()
                try repository.transitionGeneration(id: generationID, to: .succeeded, at: now())
            } catch is CancellationError {
                try? await storage.deleteExternalGenerationResult(generationID: generationID)
                throw CancellationError()
            } catch {
                try? await storage.deleteExternalGenerationResult(generationID: generationID)
                throw VirtualTryOnServiceError.recordUpdateFailed
            }
            return PersistedTryOnGeneration(
                generationID: generationID,
                resultResourceID: resources.result,
                thumbnailResourceID: resources.thumbnail,
                providerName: provider.descriptor.displayName,
                personName: personName,
                garmentsBySlot: Self.garmentNames(session: session, clothing: clothing)
            )
        } catch is CancellationError {
            markTerminal(record, status: .cancelled, code: "cancelled", message: "Generation cancelled.")
            throw VirtualTryOnError.cancelled
        } catch let error as VirtualTryOnError {
            let normalized = error == .cancelled ? GenerationStatus.cancelled : .failed
            markTerminal(record, status: normalized, code: Self.errorCode(error), message: Self.safeMessage(error))
            throw VirtualTryOnServiceError.provider(error)
        } catch let error as VirtualTryOnServiceError {
            markTerminal(record, status: .failed, code: Self.serviceErrorCode(error), message: Self.safeMessage(error))
            throw error
        } catch {
            markTerminal(record, status: .failed, code: "preparation_failed", message: "Generation preparation failed.")
            throw VirtualTryOnServiceError.preparationFailed
        }
    }

    private func callProvider(request: VirtualTryOnRequest, record: GenerationRecord) async throws -> VirtualTryOnResult {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            record.attemptCount = attempt
            record.markUpdated(at: now())
            try repository.save()
            do {
                return try await provider.generate(request: request)
            } catch VirtualTryOnError.transientFailure where attempt < maximumAttempts {
                continue
            }
        }
    }

    private func populateSnapshots(
        _ record: GenerationRecord,
        session: TryOnSession,
        person: PersonReferenceSet,
        personName: String,
        clothing: [ClothingRecord]
    ) throws {
        guard session.personProfileID == person.profileID else { throw TryOnWorkspaceError.noPerson }
        let references = [person.primaryImage].compactMap { $0 } + person.additionalImages
        let referenceByID = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0) })
        let profile = try repository.personProfile(id: person.profileID)
        for (index, imageID) in session.selectedPersonImageIDs.enumerated() {
            guard let image = referenceByID[imageID] else { throw TryOnWorkspaceError.personResourceUnavailable(imageID) }
            let resource = image.processedResourceID ?? image.originalResourceID
            record.personInputs.append(GenerationPersonInput(
                generation: record,
                personProfile: profile,
                personProfileID: person.profileID,
                personNameSnapshot: personName,
                personImage: try repository.personImage(id: imageID),
                personImageID: imageID,
                resourceIDSnapshot: resource.rawValue,
                sortOrder: index
            ))
        }
        let clothingByID = Dictionary(uniqueKeysWithValues: clothing.map { ($0.id, $0) })
        for slot in TryOnSlot.allCases {
            for (sortOrder, clothingID) in session.garmentIDs(in: slot).enumerated() {
                guard let item = clothingByID[clothingID] else { throw TryOnWorkspaceError.clothingUnavailable(clothingID) }
                let resource = item.processedResourceID ?? item.originalResourceID
                record.garmentInputs.append(GenerationGarmentInput(
                    generation: record,
                    clothingItem: try repository.clothingItem(id: clothingID),
                    clothingItemID: clothingID,
                    clothingNameSnapshot: item.draft.name,
                    categoryCodeSnapshot: item.draft.categoryCode,
                    slotCode: slot.rawValue,
                    resourceIDSnapshot: resource.rawValue,
                    sortOrder: sortOrder
                ))
            }
        }
    }

    private func markTerminal(_ record: GenerationRecord, status: GenerationStatus, code: String, message: String) {
        guard case let .known(current) = record.resolvedStatus, !current.isTerminal else { return }
        record.errorCode = code
        record.errorMessage = message
        record.completedAt = now()
        try? repository.transitionGeneration(id: record.id, to: status, at: now())
    }

    private static func optionsJSON(_ options: TryOnOptions) -> String {
        guard let data = try? JSONEncoder().encode(options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func garmentNames(session: TryOnSession, clothing: [ClothingRecord]) -> [TryOnSlot: [String]] {
        let names = Dictionary(uniqueKeysWithValues: clothing.map { ($0.id, $0.draft.name) })
        return Dictionary(uniqueKeysWithValues: TryOnSlot.allCases.map { slot in
            (slot, session.garmentIDs(in: slot).compactMap { names[$0] })
        })
    }

    private static func errorCode(_ error: VirtualTryOnError) -> String {
        switch error {
        case .invalidInput: "invalid_input"
        case .unsupportedCapability: "unsupported_capability"
        case .configurationUnavailable: "configuration_unavailable"
        case .transientFailure: "transient_failure"
        case .providerUnavailable: "provider_unavailable"
        case .invalidResponse: "invalid_response"
        case .cancelled: "cancelled"
        }
    }

    private static func serviceErrorCode(_ error: VirtualTryOnServiceError) -> String {
        switch error {
        case .recordCreationFailed: "record_creation_failed"
        case .preparationFailed: "preparation_failed"
        case .provider(let providerError): errorCode(providerError)
        case .resultStorageFailed: "result_storage_failed"
        case .recordUpdateFailed: "record_update_failed"
        }
    }

    private static func safeMessage(_ error: VirtualTryOnError) -> String {
        switch error {
        case .invalidInput, .unsupportedCapability: "Generation input is not supported."
        case .configurationUnavailable: "Provider configuration is unavailable."
        case .transientFailure: "Provider remained unavailable after limited retry."
        case .providerUnavailable: "Provider is unavailable."
        case .invalidResponse: "Provider returned an invalid response."
        case .cancelled: "Generation cancelled."
        }
    }

    private static func safeMessage(_ error: VirtualTryOnServiceError) -> String {
        switch error {
        case .recordCreationFailed: "Generation record could not be created."
        case .preparationFailed: "Generation preparation failed."
        case .provider(let providerError): safeMessage(providerError)
        case .resultStorageFailed: "Generation result could not be stored."
        case .recordUpdateFailed: "Generation result metadata could not be committed."
        }
    }
}

@MainActor
final class InterruptedGenerationRecoveryService {
    private let repository: any WardrobeRepository
    private let now: @Sendable () -> Date

    init(repository: any WardrobeRepository, now: @escaping @Sendable () -> Date = { .now }) {
        self.repository = repository
        self.now = now
    }

    @discardableResult
    func recover() throws -> Int {
        let records = try repository.nonterminalGenerationRecords()
        for record in records {
            record.errorCode = "interrupted"
            record.errorMessage = "Generation was interrupted before completion."
            record.completedAt = now()
            try repository.transitionGeneration(id: record.id, to: .failed, at: now())
        }
        return records.count
    }
}
