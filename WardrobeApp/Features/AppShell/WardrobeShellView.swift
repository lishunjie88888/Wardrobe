import Foundation
import SwiftUI

struct WardrobeShellView: View {
    let environment: AppEnvironment

    @State private var selection: AppRoute? = .wardrobe

    var body: some View {
        NavigationSplitView {
            List(AppRoute.allCases, selection: $selection) { route in
                Label(route.title, systemImage: route.systemImage)
                .tag(route)
                .accessibilityIdentifier("sidebar.route.\(route.rawValue)")
            }
            .navigationTitle(environment.applicationName)
        } detail: {
            switch selection ?? .wardrobe {
            case .wardrobe:
                WardrobeView(dependencies: environment.wardrobe)
            case .person:
                PersonView(dependencies: environment.person)
            case .tryOn:
                TryOnView(dependencies: environment.tryOn)
            case let route:
                PlaceholderFeatureView(route: route)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
#if DEBUG
            if ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_INITIAL_ROUTE"] == AppRoute.tryOn.rawValue {
                selection = .tryOn
            }
#endif
        }
    }
}

#Preview {
    let container = try! WardrobeModelContainerFactory.inMemory()
    let storage = try! StorageService(
        configuration: StorageConfiguration(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("WardrobePreview", isDirectory: true)
        )
    )
    WardrobeShellView(
        environment: try! AppEnvironment(
            applicationName: "Wardrobe",
            modelContainer: container,
            storageService: storage,
            imageProcessingService: ImageProcessingService(storage: storage)
        )
    )
}
