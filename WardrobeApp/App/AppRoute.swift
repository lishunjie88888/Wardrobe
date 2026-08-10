import Foundation

enum AppRoute: String, CaseIterable, Hashable, Identifiable, Sendable {
    case wardrobe
    case tryOn
    case outfits
    case generationHistory
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .wardrobe: "我的衣橱"
        case .tryOn: "AI 试衣间"
        case .outfits: "穿搭"
        case .generationHistory: "生成历史"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .wardrobe: "cabinet"
        case .tryOn: "sparkles.rectangle.stack"
        case .outfits: "square.grid.2x2"
        case .generationHistory: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}
