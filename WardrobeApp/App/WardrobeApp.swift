import SwiftData
import SwiftUI

@main
struct WardrobeApp: App {
    private let environment: AppEnvironment

    init() {
        do {
            environment = try .production()
        } catch {
            fatalError("Unable to initialize the Wardrobe data store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            WardrobeShellView(environment: environment)
        }
        .modelContainer(environment.modelContainer)
    }
}
