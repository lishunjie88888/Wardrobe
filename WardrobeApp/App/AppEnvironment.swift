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

    @MainActor
    init(
        applicationName: String,
        modelContainer: ModelContainer,
        storageService: StorageService,
        imageProcessingService: any ImageProcessingServing
    ) throws {
        self.applicationName = applicationName
        self.modelContainer = modelContainer
        self.providerRegistry = try ProviderRegistry(providers: [MockVirtualTryOnProvider()])
        let repository = SwiftDataWardrobeRepository(container: modelContainer)
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
#endif
        let inspector = ResourceReferenceInspector(repository: repository)
        let clothingStorage = storageService
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
    }

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
