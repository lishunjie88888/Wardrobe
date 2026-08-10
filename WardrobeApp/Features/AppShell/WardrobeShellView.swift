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
            PlaceholderFeatureView(route: selection ?? .wardrobe)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

#Preview {
    WardrobeShellView(environment: .production())
}
