import Foundation
import SwiftUI

struct WardrobeShellView: View {
    let environment: AppEnvironment

    @State private var selection: AppRoute? = .wardrobe

    init(environment: AppEnvironment) {
        self.environment = environment
#if DEBUG
        let requestedRoute = ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_INITIAL_ROUTE"]
        _selection = State(initialValue: requestedRoute.flatMap(AppRoute.init(rawValue:)) ?? .wardrobe)
#endif
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text("Wardrobe")
                        .font(.title3.bold())
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)

                VStack(spacing: 6) {
                    ForEach(AppRoute.allCases) { route in
                        Button {
                            selection = route
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: route.systemImage)
                                    .frame(width: 20)
                                Text(route.title)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                            .background(
                                selection == route ? Color.accentColor.opacity(0.16) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar.route.\(route.rawValue)")
                    }
                }
                .padding(10)

                Spacer(minLength: 20)

                VStack(alignment: .leading, spacing: 8) {
                    Label("本地资料库", systemImage: "internaldrive")
                        .font(.caption.bold())
                    Text("数据仅保存在本机")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Wardrobe")
            .navigationSplitViewColumnWidth(min: 210, ideal: 210, max: 210)
            .background(.bar)
        } detail: {
            switch selection ?? .wardrobe {
            case .wardrobe:
                WardrobeView(dependencies: environment.wardrobe)
            case .person:
                PersonView(dependencies: environment.person)
            case .tryOn:
                TryOnView(dependencies: environment.tryOn)
            case .outfits:
                OutfitView(dependencies: environment.outfit) { result in
                    environment.tryOnWorkspaceCoordinator.requestLoad(result)
                    selection = .tryOn
                } goToTryOn: {
                    selection = .tryOn
                }
            case .generationHistory:
                GenerationHistoryView(dependencies: environment.generationHistory) { request in
                    environment.tryOnWorkspaceCoordinator.requestRegenerate(request)
                    selection = .tryOn
                }
            case let route:
                PlaceholderFeatureView(route: route)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 620)
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
