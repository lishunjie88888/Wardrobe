import Foundation

/// The application composition root. Concrete dependencies are added here as
/// their owning stages are implemented.
struct AppEnvironment: Sendable {
    let applicationName: String

    static func production() -> AppEnvironment {
        AppEnvironment(applicationName: "Wardrobe")
    }
}
