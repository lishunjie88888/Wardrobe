import SwiftUI

@main
struct WardrobeApp: App {
    private let environment: AppEnvironment

    init() {
        environment = .production()
    }

    var body: some Scene {
        WindowGroup {
            WardrobeShellView(environment: environment)
        }
    }
}
