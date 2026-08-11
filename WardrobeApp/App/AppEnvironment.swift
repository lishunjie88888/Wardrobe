import Foundation
import SwiftData

/// The application composition root. Concrete dependencies are added here as
/// their owning stages are implemented.
struct AppEnvironment: Sendable {
    let applicationName: String
    let modelContainer: ModelContainer
    let storageService: any StorageServing
    let imageProcessingService: any ImageProcessingServing

    init(
        applicationName: String,
        modelContainer: ModelContainer,
        storageService: any StorageServing,
        imageProcessingService: any ImageProcessingServing
    ) {
        self.applicationName = applicationName
        self.modelContainer = modelContainer
        self.storageService = storageService
        self.imageProcessingService = imageProcessingService
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
