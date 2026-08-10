import Foundation
import SwiftData

/// The application composition root. Concrete dependencies are added here as
/// their owning stages are implemented.
struct AppEnvironment: Sendable {
    let applicationName: String
    let modelContainer: ModelContainer

    @MainActor
    static func production() throws -> AppEnvironment {
        AppEnvironment(
            applicationName: "Wardrobe",
            modelContainer: try WardrobeModelContainerFactory.production()
        )
    }
}
