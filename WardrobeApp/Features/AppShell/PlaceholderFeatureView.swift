import SwiftUI

struct PlaceholderFeatureView: View {
    let route: AppRoute

    var body: some View {
        ContentUnavailableView {
            Label(route.title, systemImage: route.systemImage)
                .accessibilityIdentifier("placeholder.\(route.rawValue)")
        } description: {
            Text("此功能将在后续阶段实现。")
        }
        .navigationTitle(route.title)
    }
}
