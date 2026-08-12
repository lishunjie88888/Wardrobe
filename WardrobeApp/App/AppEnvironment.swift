import Foundation
import SwiftData

/// The application composition root. Concrete dependencies are added here as
/// their owning stages are implemented.
struct WardrobeFeatureDependencies {
    let management: ClothingManagementService
    let importer: ImportClothingService
    let deletion: ClothingDeletionService
    let imageLoader: any ClothingImageLoading
}

struct AppEnvironment {
    let applicationName: String
    let modelContainer: ModelContainer
    let wardrobe: WardrobeFeatureDependencies
    let person: PersonFeatureDependencies
    let providerRegistry: ProviderRegistry
    let tryOn: TryOnFeatureDependencies
    let outfit: OutfitFeatureDependencies
    let tryOnWorkspaceCoordinator: TryOnWorkspaceCoordinator

    @MainActor
    init(
        applicationName: String,
        modelContainer: ModelContainer,
        storageService: StorageService,
        imageProcessingService: any ImageProcessingServing
    ) throws {
        self.applicationName = applicationName
        self.modelContainer = modelContainer
        let mockProvider = MockVirtualTryOnProvider(behavior: .success(delay: .milliseconds(350)))
        self.providerRegistry = try ProviderRegistry(providers: [mockProvider])
        let repository = SwiftDataWardrobeRepository(container: modelContainer)
        let outfitService = OutfitService(repository: repository)
        let tryOnWorkspaceCoordinator = TryOnWorkspaceCoordinator()
        self.tryOnWorkspaceCoordinator = tryOnWorkspaceCoordinator
        try InterruptedGenerationRecoveryService(repository: repository).recover()
#if DEBUG
        if ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_SEED_CLOTHING"] == "1" {
            let seedID = UUID(uuidString: "00000000-0000-0000-0000-000000000404")!
            if (try? repository.clothingItem(id: seedID)) == nil {
                if let original = try? StorageResourceID(
                    owner: StorageOwner(kind: .garment, id: seedID),
                    kind: .original(fileExtension: "jpg")
                ) {
                    try? repository.insertAndSave(ClothingItem(
                        id: seedID,
                        name: "UI 测试外套",
                        categoryCode: ClothingCategory.outerwear.rawValue,
                        originalResourceID: original.rawValue
                    ))
                }
            }
        }
        if ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_SEED_PERSON"] == "1" {
            let seedID = UUID(uuidString: "00000000-0000-0000-0000-000000000505")!
            if (try? repository.personProfile(id: seedID)) == nil {
                let profile = PersonProfile(id: seedID, name: "UI 测试人物", notes: "隔离测试资料")
                let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000511")!
                let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000512")!
                let firstOwner = StorageOwner(kind: .person, id: firstID)
                let secondOwner = StorageOwner(kind: .person, id: secondID)
                if let firstResource = try? StorageResourceID(owner: firstOwner, kind: .original(fileExtension: "jpg")),
                   let secondResource = try? StorageResourceID(owner: secondOwner, kind: .original(fileExtension: "jpg")) {
                    let first = PersonImage(id: firstID, profile: profile, isPrimary: true, originalResourceID: firstResource.rawValue)
                    let second = PersonImage(id: secondID, profile: profile, originalResourceID: secondResource.rawValue)
                    profile.images = [first, second]
                    try? repository.insert(profile)
                    try? repository.insert(first)
                    try? repository.insert(second)
                }
                try? repository.save()
            }
        }
        if ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_SEED_TRYON"] == "1" {
            Self.seedTryOnFixture(repository: repository)
        }
#endif
        let inspector = ResourceReferenceInspector(repository: repository)
        let clothingStorage = storageService
        let externalWorkspace = try ExternalGenerationWorkspace(rootURL: storageService.libraryRootURL)
        self.wardrobe = WardrobeFeatureDependencies(
            management: ClothingManagementService(repository: repository),
            importer: ImportClothingService(
                repository: repository,
                storage: clothingStorage,
                imageProcessing: imageProcessingService
            ),
            deletion: ClothingDeletionService(
                repository: repository,
                inspector: inspector,
                storage: clothingStorage
            ),
            imageLoader: clothingStorage
        )
        self.person = PersonFeatureDependencies(
            management: PersonManagementService(repository: repository),
            importer: ImportPersonImageService(
                repository: repository,
                storage: clothingStorage,
                imageProcessing: imageProcessingService
            ),
            imageDeletion: PersonImageDeletionService(
                repository: repository,
                inspector: inspector,
                storage: clothingStorage
            ),
            profileDeletion: PersonProfileDeletionService(
                repository: repository,
                inspector: inspector,
                storage: clothingStorage
            ),
            imageLoader: clothingStorage
        )
        self.outfit = OutfitFeatureDependencies(service: outfitService, imageLoader: clothingStorage)
#if DEBUG
        let tryOnLoader: any TryOnResourceLoading = ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_SEED_TRYON"] == "1"
            ? UITestTryOnImageLoader(base: clothingStorage)
            : clothingStorage
#else
        let tryOnLoader: any TryOnResourceLoading = clothingStorage
#endif
#if DEBUG
        let externalClipboard: any ClipboardServing = ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_SEED_TRYON"] == "1"
            ? UITestClipboardService()
            : SystemClipboardService()
        let externalLauncher: any ExternalAILaunching = ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_SEED_TRYON"] == "1"
            ? UITestExternalAILauncher()
            : SystemExternalAILauncher()
#else
        let externalClipboard: any ClipboardServing = SystemClipboardService()
        let externalLauncher: any ExternalAILaunching = SystemExternalAILauncher()
#endif
#if DEBUG
        let injectedResultURL: URL? = {
            guard ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_EXTERNAL_RESULT"] == "1" else { return nil }
            let url = storageService.libraryRootURL.appendingPathComponent("staging/ui-external-result.png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")?.write(to: url)
            return url
        }()
#else
        let injectedResultURL: URL? = nil
#endif
        self.tryOn = TryOnFeatureDependencies(
            clothing: ClothingManagementService(repository: repository),
            person: PersonManagementService(repository: repository),
            imageLoader: tryOnLoader,
            provider: mockProvider,
            generationService: VirtualTryOnService(
                repository: repository,
                storage: storageService,
                requestBuilder: VirtualTryOnRequestBuilder(loader: tryOnLoader),
                provider: mockProvider
            ),
            externalWorkflow: ExternalGenerationWorkflow(
                builder: ExternalGenerationPackageBuilder(loader: tryOnLoader, workspace: externalWorkspace),
                clipboard: externalClipboard,
                launcher: externalLauncher,
                workspace: externalWorkspace
            ),
            resultImporter: ExternalGenerationResultImporter(repository: repository, storage: storageService),
            injectedResultURL: injectedResultURL,
            workspaceCoordinator: tryOnWorkspaceCoordinator,
            outfitService: outfitService
        )
    }


#if DEBUG
    @MainActor
    private static func seedTryOnFixture(repository: SwiftDataWardrobeRepository) {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000707")!
        let imageID = UUID(uuidString: "00000000-0000-0000-0000-000000000711")!
        if (try? repository.personProfile(id: profileID)) == nil,
           let original = try? StorageResourceID(owner: StorageOwner(kind: .person, id: imageID), kind: .original(fileExtension: "png")),
           let processed = try? StorageResourceID(owner: StorageOwner(kind: .person, id: imageID), kind: .processed) {
            let profile = PersonProfile(id: profileID, name: "试衣测试人物", isDefault: true)
            let image = PersonImage(id: imageID, profile: profile, isPrimary: true, originalResourceID: original.rawValue, processedResourceID: processed.rawValue, pixelWidth: 1, pixelHeight: 1)
            try? repository.insert(profile)
            try? repository.insert(image)
        }
        let fixtures: [(String, ClothingCategory, String)] = [
            ("00000000-0000-0000-0000-000000000721", .tops, "试衣测试上衣"),
            ("00000000-0000-0000-0000-000000000722", .bottoms, "试衣测试下装"),
            ("00000000-0000-0000-0000-000000000723", .footwear, "试衣测试鞋履"),
        ]
        for (rawID, category, name) in fixtures {
            let id = UUID(uuidString: rawID)!
            guard (try? repository.clothingItem(id: id)) == nil,
                  let original = try? StorageResourceID(owner: StorageOwner(kind: .garment, id: id), kind: .original(fileExtension: "png")),
                  let processed = try? StorageResourceID(owner: StorageOwner(kind: .garment, id: id), kind: .processed)
            else { continue }
            try? repository.insert(ClothingItem(id: id, name: name, categoryCode: category.rawValue, originalResourceID: original.rawValue, processedResourceID: processed.rawValue))
        }
        try? repository.save()
    }
#endif

    @MainActor
    static func production() throws -> AppEnvironment {
        let storageConfiguration = try StorageConfiguration.production()
        let storageService = try StorageService(configuration: storageConfiguration)
        return try AppEnvironment(
            applicationName: "Wardrobe",
            modelContainer: try WardrobeModelContainerFactory.production(
                databaseDirectory: storageConfiguration.rootURL.appendingPathComponent("database", isDirectory: true)
            ),
            storageService: storageService,
            imageProcessingService: ImageProcessingService(storage: storageService)
        )
    }
}

#if DEBUG
private struct UITestTryOnImageLoader: TryOnResourceLoading {
    let base: any TryOnResourceLoading

    func data(for resourceID: StorageResourceID) async throws -> Data {
        if resourceID.owner.id.uuidString.hasPrefix("00000000-0000-0000-0000-0000000007") {
            return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        }
        return try await base.data(for: resourceID)
    }
}

@MainActor
private final class UITestClipboardService: ClipboardServing {
    func copy(_: String) -> Bool { true }
}

@MainActor
private final class UITestExternalAILauncher: ExternalAILaunching {
    func openChatGPT() -> Bool { true }
    func revealInFinder(_: URL) -> Bool { true }
}
#endif
