import Foundation
import Observation

struct TryOnFeatureDependencies {
    let clothing: ClothingManagementService
    let person: PersonManagementService
    let imageLoader: any TryOnResourceLoading
    let provider: any VirtualTryOnProvider
    let generationService: VirtualTryOnService?
    let externalWorkflow: ExternalGenerationWorkflow?
    let resultImporter: ExternalGenerationResultImporter?
    let injectedResultURL: URL?

    init(
        clothing: ClothingManagementService,
        person: PersonManagementService,
        imageLoader: any TryOnResourceLoading,
        provider: any VirtualTryOnProvider,
        generationService: VirtualTryOnService? = nil,
        externalWorkflow: ExternalGenerationWorkflow? = nil,
        resultImporter: ExternalGenerationResultImporter? = nil,
        injectedResultURL: URL? = nil
    ) {
        self.clothing = clothing
        self.person = person
        self.imageLoader = imageLoader
        self.provider = provider
        self.generationService = generationService
        self.externalWorkflow = externalWorkflow
        self.resultImporter = resultImporter
        self.injectedResultURL = injectedResultURL
    }
}

struct MockTryOnPreview: Equatable, Sendable {
    let providerName: String
    let personName: String
    let garmentsBySlot: [TryOnSlot: [String]]
    let requestID: UUID
    let resultResourceID: StorageResourceID?
}

@MainActor
@Observable
final class TryOnViewModel {
    enum GenerationState: Equatable {
        case idle
        case validating
        case generating
        case success(MockTryOnPreview)
        case failure(String)
        case cancelled
    }

    enum ExternalState: Equatable {
        case idle
        case preparing
        case ready(ExternalGenerationWorkflow.PreparationResult)
        case importing(ExternalGenerationPackage)
        case imported(ExternalGenerationPackage, ImportedExternalGeneration)
        case failure(String)
    }

    private let dependencies: TryOnFeatureDependencies
    private let mapper = ClothingToTryOnSlotMapper()
    private let requestBuilder: VirtualTryOnRequestBuilder
    private var generationTask: Task<Void, Never>?
    private var generationToken: UUID?

    var session = TryOnSession()
    var clothing: [ClothingRecord] = []
    private var allActiveClothing: [ClothingRecord] = []
    var profiles: [PersonProfileRecord] = []
    var currentReferences: PersonReferenceSet?
    var searchText = ""
    var categoryCode: String?
    var favoritesOnly = false
    var generationState: GenerationState = .idle
    var externalState: ExternalState = .idle
    var message: String?
    var omittedReferenceCount = 0

    init(dependencies: TryOnFeatureDependencies) {
        self.dependencies = dependencies
        self.requestBuilder = VirtualTryOnRequestBuilder(loader: dependencies.imageLoader)
    }

    var provider: any VirtualTryOnProvider { dependencies.provider }
    var imageLoader: any TryOnResourceLoading { dependencies.imageLoader }
    var selectedProfile: PersonProfileRecord? { profiles.first { $0.id == session.personProfileID } }
    var isGenerating: Bool { if case .generating = generationState { true } else { false } }
    var canGenerate: Bool {
        session.personProfileID != nil && !session.selectedPersonImageIDs.isEmpty && session.garmentCount > 0 && !isGenerating && !isPreparingExternal
    }

    var isPreparingExternal: Bool { if case .preparing = externalState { true } else { false } }
    var preparedPackage: ExternalGenerationPackage? {
        switch externalState {
        case .ready(let result): result.package
        case .importing(let package), .imported(let package, _): package
        default: nil
        }
    }
    var importedResult: ImportedExternalGeneration? {
        if case .imported(_, let result) = externalState { result } else { nil }
    }
    var injectedResultURL: URL? { dependencies.injectedResultURL }

    func load() {
        do {
            var query = ClothingQuery()
            query.searchText = searchText
            query.categoryCode = categoryCode
            query.favoritesOnly = favoritesOnly
            query.archive = .active
            clothing = try dependencies.clothing.clothing(matching: query)
            allActiveClothing = try dependencies.clothing.clothing(matching: ClothingQuery())
            profiles = try dependencies.person.profiles(archive: .active)
            session.reconcile(activeClothingIDs: Set(allActiveClothing.map(\.id)))

            let requestedProfileID = session.personProfileID
            let defaultSet = try dependencies.person.defaultReferenceSet()
            let resolvedProfileID: UUID?
            if let requestedProfileID, profiles.contains(where: { $0.id == requestedProfileID }) {
                resolvedProfileID = requestedProfileID
            } else if let defaultSet {
                resolvedProfileID = defaultSet.profileID
            } else {
                resolvedProfileID = profiles.first?.id
            }
            if resolvedProfileID != session.personProfileID {
                selectPerson(resolvedProfileID)
            } else if let resolvedProfileID {
                refreshReferences(profileID: resolvedProfileID, preserveSelection: true)
            } else {
                session.selectPerson(profileID: nil, referenceImageIDs: [])
                currentReferences = nil
            }
        } catch {
            message = "无法载入试衣工作区，请稍后重试。"
        }
    }

    func filtersChanged() { load() }

    func selectPerson(_ profileID: UUID?) {
        cancelGeneration(setCancelledState: false)
        generationState = .idle
        guard let profileID else {
            session.selectPerson(profileID: nil, referenceImageIDs: [])
            currentReferences = nil
            return
        }
        refreshReferences(profileID: profileID, preserveSelection: false)
    }

    func toggleReference(_ imageID: UUID) {
        if session.selectedPersonImageIDs.contains(imageID) {
            guard session.selectedPersonImageIDs.count > 1 else {
                message = "至少保留一张人物参考照。"
                return
            }
            session.selectedPersonImageIDs.removeAll { $0 == imageID }
        } else if session.selectedPersonImageIDs.count < provider.capabilities.maxPersonImages {
            session.selectedPersonImageIDs.append(imageID)
        } else {
            message = "当前 Provider 最多支持 \(provider.capabilities.maxPersonImages) 张人物参考照。"
        }
        invalidateResult()
    }

    @discardableResult
    func addClothing(_ clothingID: UUID, to requestedSlot: TryOnSlot? = nil) -> Bool {
        guard let item = clothing.first(where: { $0.id == clothingID }), !item.isArchived else {
            message = "这件衣物已不可用，已从当前搭配中移除。"
            session.reconcile(activeClothingIDs: Set(allActiveClothing.map(\.id)))
            return false
        }
        guard case let .supported(mappedSlot) = mapper.slot(for: item.draft.categoryCode, subcategoryCode: item.draft.subcategoryCode) else {
            message = "“\(item.draft.name)”暂时无法可靠映射到试衣槽位。"
            return false
        }
        let slot = requestedSlot ?? mappedSlot
        guard slot == mappedSlot else {
            message = "“\(item.draft.name)”不适用于这个槽位。"
            return false
        }
        guard provider.capabilities.supportedSlots.contains(slot) else {
            message = "当前 Provider 不支持这个槽位。"
            return false
        }
        let limit = provider.capabilities.maxGarmentsBySlot[slot] ?? 0
        if slot.permitsMultipleItems, session.garmentIDs(in: slot).count >= limit {
            message = "这个槽位最多可放入 \(limit) 件衣物。"
            return false
        }
        session.add(clothingID: clothingID, to: slot)
        invalidateResult()
        return true
    }

    func removeClothing(_ clothingID: UUID, from slot: TryOnSlot) {
        session.remove(clothingID: clothingID, from: slot)
        invalidateResult()
    }

    func moveAccessories(fromOffsets: IndexSet, toOffset: Int) {
        session.moveAccessory(fromOffsets: fromOffsets, toOffset: toOffset)
        invalidateResult()
    }

    func clearOutfit() {
        session.clearGarments()
        invalidateResult()
    }

    func generate() {
        guard generationTask == nil else { return }
        let token = UUID()
        generationToken = token
        generationState = .validating
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generationToken == token {
                    generationTask = nil
                    generationToken = nil
                }
            }
            do {
                guard let references = currentReferences, let profile = selectedProfile else {
                    throw TryOnWorkspaceError.noPerson
                }
                generationState = .generating
                let result: PersistedTryOnGeneration
                if let service = dependencies.generationService {
                    result = try await service.generate(
                        session: session,
                        person: references,
                        personName: profile.draft.name,
                        clothing: allActiveClothing
                    )
                } else {
                    let request = try await requestBuilder.build(
                        session: session,
                        person: references,
                        clothing: allActiveClothing,
                        capabilities: provider.capabilities
                    )
                    try await provider.validateConfiguration()
                    _ = try await provider.generate(request: request)
                    result = PersistedTryOnGeneration(
                        generationID: request.requestID,
                        resultResourceID: try StorageResourceID(owner: StorageOwner(kind: .generation, id: request.requestID), kind: .generationResult(fileExtension: "png")),
                        thumbnailResourceID: try StorageResourceID(owner: StorageOwner(kind: .generation, id: request.requestID), kind: .thumbnail),
                        providerName: provider.descriptor.displayName,
                        personName: profile.draft.name,
                        garmentsBySlot: garmentNamesBySlot()
                    )
                }
                try Task.checkCancellation()
                guard generationToken == token else { return }
                generationState = .success(MockTryOnPreview(
                    providerName: result.providerName,
                    personName: result.personName,
                    garmentsBySlot: result.garmentsBySlot,
                    requestID: result.generationID,
                    resultResourceID: dependencies.generationService == nil ? nil : result.resultResourceID
                ))
            } catch is CancellationError {
                if generationToken == token { generationState = .cancelled }
            } catch let error as VirtualTryOnError where error == .cancelled {
                if generationToken == token { generationState = .cancelled }
            } catch {
                if generationToken == token { generationState = .failure(Self.message(for: error)) }
            }
        }
    }

    func retry() { generate() }

    func prepareExternalGeneration() {
        guard canGenerate, let references = currentReferences, let workflow = dependencies.externalWorkflow else { return }
        externalState = .preparing
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await workflow.prepare(
                    session: session,
                    person: references,
                    clothing: allActiveClothing
                )
                externalState = .ready(result)
            } catch {
                let failureMessage = Self.externalMessage(for: error)
                externalState = .failure(failureMessage)
                message = failureMessage
            }
        }
    }

    func copyPreparedPrompt() {
        guard let package = preparedPackage else { return }
        if dependencies.externalWorkflow?.copyPrompt(from: package) != true {
            message = "自动复制提示词失败，可在素材文件夹中打开 prompt.txt 手动复制。"
        }
    }

    func openChatGPT() {
        if dependencies.externalWorkflow?.openChatGPT() != true { message = "无法打开 ChatGPT，请手动打开应用或网页。" }
    }

    func revealPreparedPackage() {
        guard let package = preparedPackage else { return }
        if dependencies.externalWorkflow?.reveal(package) != true { message = "无法在 Finder 中显示素材，请稍后重试。" }
    }

    func importExternalResult(from sourceURL: URL) {
        guard let package = preparedPackage, let importer = dependencies.resultImporter else { return }
        externalState = .importing(package)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await importer.importResult(from: sourceURL, package: package)
                externalState = .imported(package, result)
            } catch {
                externalState = .ready(.init(package: package, promptCopied: false, chatGPTOpened: false, finderOpened: false))
                message = Self.externalMessage(for: error)
            }
        }
    }

    func cleanPreparedPackage() {
        guard let package = preparedPackage, let workflow = dependencies.externalWorkflow else { return }
        Task { [weak self] in
            do {
                try await workflow.delete(package)
                self?.externalState = .idle
            } catch {
                self?.message = "无法清理这次临时素材，正式人物、衣物和生成结果未受影响。"
            }
        }
    }

    func cancelGeneration(setCancelledState: Bool = true) {
        guard generationTask != nil else { return }
        generationTask?.cancel()
        generationToken = nil
        generationTask = nil
        if setCancelledState { generationState = .cancelled }
    }

    func clothingRecord(id: UUID) -> ClothingRecord? { allActiveClothing.first { $0.id == id } }

    private func refreshReferences(profileID: UUID, preserveSelection: Bool) {
        do {
            guard let set = try dependencies.person.referenceSet(profileID: profileID) else {
                session.selectPerson(profileID: profileID, referenceImageIDs: [])
                currentReferences = nil
                message = "当前人物没有可用参考照片。"
                return
            }
            currentReferences = set
            let ordered = [set.primaryImage].compactMap { $0 } + set.additionalImages
            let availableIDs = Set(ordered.map(\.id))
            let selected: [UUID]
            if preserveSelection {
                let preserved = session.selectedPersonImageIDs.filter(availableIDs.contains)
                selected = preserved.isEmpty ? Array(ordered.prefix(provider.capabilities.maxPersonImages).map(\.id)) : preserved
            } else {
                selected = Array(ordered.prefix(provider.capabilities.maxPersonImages).map(\.id))
            }
            omittedReferenceCount = max(0, ordered.count - provider.capabilities.maxPersonImages)
            session.selectPerson(profileID: profileID, referenceImageIDs: selected)
        } catch {
            session.selectPerson(profileID: profileID, referenceImageIDs: [])
            currentReferences = nil
            message = "无法读取人物参考照。"
        }
    }

    private func invalidateResult() {
        cancelGeneration(setCancelledState: false)
        generationState = .idle
        externalState = .idle
    }

    private func garmentNamesBySlot() -> [TryOnSlot: [String]] {
        Dictionary(uniqueKeysWithValues: TryOnSlot.allCases.map { slot in
            (slot, session.garmentIDs(in: slot).compactMap { clothingRecord(id: $0)?.draft.name })
        })
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TryOnWorkspaceError.noPerson: "请选择人物。"
        case TryOnWorkspaceError.personHasNoReference: "当前人物没有可用参考照片。"
        case TryOnWorkspaceError.noGarments: "请至少加入一件衣物。"
        case TryOnWorkspaceError.clothingUnavailable: "当前搭配中有衣物已不可用。"
        case TryOnWorkspaceError.garmentResourceUnavailable, TryOnWorkspaceError.personResourceUnavailable, TryOnWorkspaceError.invalidImageResource: "参考图片不可用，请重新导入或选择其他素材。"
        case TryOnWorkspaceError.referenceLimitExceeded(let maximum): "当前 Provider 最多支持 \(maximum) 张人物参考照。"
        case TryOnWorkspaceError.unsupportedClothing, TryOnWorkspaceError.incompatibleSlot: "衣物与试衣槽位不兼容。"
        case TryOnWorkspaceError.provider(let providerError): providerMessage(providerError)
        case let providerError as VirtualTryOnError: providerMessage(providerError)
        case VirtualTryOnServiceError.provider(let providerError): providerMessage(providerError)
        case VirtualTryOnServiceError.resultStorageFailed: "无法保存 Mock 结果，请检查本地存储后重试。"
        case VirtualTryOnServiceError.recordCreationFailed, VirtualTryOnServiceError.recordUpdateFailed: "无法保存生成记录，请稍后重试。"
        case VirtualTryOnServiceError.preparationFailed: "无法准备 Mock 生成，请检查当前素材。"
        default: "Mock 生成失败，请检查当前素材后重试。"
        }
    }

    private static func providerMessage(_ error: VirtualTryOnError) -> String {
        switch error {
        case .transientFailure: "Mock Provider 暂时不可用，可以重试。"
        case .providerUnavailable, .configurationUnavailable: "Mock Provider 当前不可用。"
        case .cancelled: "生成已取消。"
        case .invalidInput, .unsupportedCapability: "当前人物、衣物或选项不满足 Provider 要求。"
        case .invalidResponse: "Mock Provider 返回了无效结果。"
        }
    }

    private static func externalMessage(for error: any Error) -> String {
        switch error {
        case ExternalGenerationError.noPerson: "请选择人物。"
        case ExternalGenerationError.personHasNoReference: "当前人物没有可用参考照片。"
        case ExternalGenerationError.noGarments: "请至少加入一件衣物。"
        case ExternalGenerationError.missingResource: "人物或衣物参考图片缺失，请重新选择素材。"
        case ExternalGenerationError.invalidResultImage: "所选文件不是可正常解码的图片。"
        case ExternalGenerationError.packageCreationFailed: "无法准备 ChatGPT 素材，请检查可用磁盘空间后重试。"
        case ExternalGenerationError.resultStorageFailed: "无法保存生成图片，请检查本地存储后重试。"
        case ExternalGenerationError.generationRecordFailed: "无法保存生成记录，未保留不完整的结果文件。"
        default: "外部 ChatGPT 工作流未完成，请稍后重试。"
        }
    }
}
