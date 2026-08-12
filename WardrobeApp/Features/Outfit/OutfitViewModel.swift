import Foundation
import Observation

struct OutfitFeatureDependencies {
    let service: OutfitService
    let imageLoader: any ClothingImageLoading
}

@MainActor
@Observable
final class OutfitViewModel {
    private let dependencies: OutfitFeatureDependencies
    var outfits: [OutfitRecord] = []
    var selection: UUID?
    var query = OutfitQuery()
    var message: String?
    var pendingLoad: OutfitLoadResult?

    init(dependencies: OutfitFeatureDependencies) { self.dependencies = dependencies }

    var imageLoader: any ClothingImageLoading { dependencies.imageLoader }
    var selectedOutfit: OutfitRecord? { outfits.first { $0.id == selection } }

    func load() {
        do {
            outfits = try dependencies.service.outfits(matching: query)
            if let selection, !outfits.contains(where: { $0.id == selection }) { self.selection = outfits.first?.id }
            else if selection == nil { selection = outfits.first?.id }
        } catch { message = "无法载入穿搭，请稍后重试。" }
    }

    func clearFilters() { query = OutfitQuery(); load() }

    func update(_ draft: OutfitDraft) {
        guard let id = selection else { return }
        perform { _ = try dependencies.service.update(id: id, draft: draft); load() }
    }

    func toggleFavorite(_ outfit: OutfitRecord) {
        perform { _ = try dependencies.service.setFavorite(id: outfit.id, isFavorite: !outfit.draft.isFavorite); load() }
    }

    func setArchived(_ outfit: OutfitRecord, archived: Bool) {
        perform { _ = try dependencies.service.setArchived(id: outfit.id, archived: archived); load() }
    }

    func permanentlyDelete(_ outfit: OutfitRecord) {
        perform { try dependencies.service.permanentlyDelete(id: outfit.id); selection = nil; load() }
    }

    func preflight(_ outfit: OutfitRecord) {
        perform {
            let result = try dependencies.service.preflightLoad(id: outfit.id)
            guard result.canLoad else { throw OutfitServiceError.noLoadableItems }
            pendingLoad = result
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { message = (error as? LocalizedError)?.errorDescription ?? "操作失败，请稍后重试。" }
    }
}
