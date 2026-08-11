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

    @MainActor
    init(
        applicationName: String,
        modelContainer: ModelContainer,
        storageService: StorageService,
        imageProcessingService: any ImageProcessingServing
    ) {
        self.applicationName = applicationName
        self.modelContainer = modelContainer
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
    }

    @MainActor
    static func production() throws -> AppEnvironment {
        let storageConfiguration = try StorageConfiguration.production()
        let storageService = try StorageService(configuration: storageConfiguration)
        return AppEnvironment(
            applicationName: "Wardrobe",
            modelContainer: try WardrobeModelContainerFactory.production(
                databaseDirectory: storageConfiguration.rootURL.appendingPathComponent("database", isDirectory: true)
            ),
            storageService: storageService,
            imageProcessingService: ImageProcessingService(storage: storageService)
        )
    }
}
