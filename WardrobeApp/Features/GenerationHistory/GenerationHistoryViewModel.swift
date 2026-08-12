import Foundation
import Observation

struct GenerationHistoryFeatureDependencies {
    let service: GenerationHistoryService
    let imageLoader: any GenerationHistoryImageLoading
}

@MainActor
@Observable
final class GenerationHistoryViewModel {
    private let dependencies: GenerationHistoryFeatureDependencies
    var records: [GenerationHistoryRecord] = []
    var selection: UUID?
    var detail: GenerationDetailRecord?
    var query = GenerationHistoryQuery()
    var providerIDs: [String] = []
    var message: String?
    var deleteImpact: GenerationDeleteImpact?
    var outfitPreflight: GenerationSaveOutfitPreflight?

    init(dependencies: GenerationHistoryFeatureDependencies) { self.dependencies = dependencies }

    var imageLoader: any GenerationHistoryImageLoading { dependencies.imageLoader }

    func load() {
        do {
            providerIDs = Array(Set(try dependencies.service.history().map(\.providerID))).sorted()
            records = try dependencies.service.history(matching: query)
            if let selection, !records.contains(where: { $0.id == selection }) { self.selection = records.first?.id }
            else if selection == nil { selection = records.first?.id }
            loadDetail()
        } catch { message = "无法载入生成历史，请稍后重试。" }
    }

    func select(_ id: UUID) { selection = id; loadDetail() }
    func clearFilters() { query = GenerationHistoryQuery(); load() }

    func regenerate(_ detail: GenerationDetailRecord, handoff: @escaping (GenerationRegenerateRequest) -> Void) {
        Task {
            do {
                let result = try await dependencies.service.regeneratePreflight(id: detail.id)
                guard let request = result.request, result.canRegenerate else {
                    message = unavailableMessage("此记录暂时无法完整重新生成", result.unavailableInputs)
                    return
                }
                handoff(request)
            } catch { message = localized(error) }
        }
    }

    func preflightSaveOutfit(_ detail: GenerationDetailRecord) {
        Task {
            do {
                let result = try await dependencies.service.saveOutfitPreflight(id: detail.id)
                guard result.canSave else {
                    message = unavailableMessage("此生成中的部分衣物当前不可用于创建穿搭", result.unavailableInputs)
                    return
                }
                outfitPreflight = result
            } catch { message = localized(error) }
        }
    }

    func saveOutfit(_ detail: GenerationDetailRecord, draft: OutfitDraft) {
        Task {
            do {
                let outfit = try await dependencies.service.saveAsOutfit(id: detail.id, draft: draft)
                outfitPreflight = nil
                message = "已保存为穿搭“\(outfit.draft.name)”。"
            } catch { message = localized(error) }
        }
    }

    func preflightDelete(_ detail: GenerationDetailRecord) {
        do { deleteImpact = try dependencies.service.deleteImpact(id: detail.id) }
        catch { message = localized(error) }
    }

    func confirmDelete() {
        guard let impact = deleteImpact else { return }
        deleteImpact = nil
        Task {
            do {
                let result = try await dependencies.service.permanentlyDelete(id: impact.generationID)
                selection = nil
                load()
                message = result.cleanupIssueCount == 0 ? "生成记录已删除。" : "生成记录已删除；有 \(result.cleanupIssueCount) 个结果文件未能清理，可稍后重试。"
            } catch { message = localized(error) }
        }
    }

    private func loadDetail() {
        do { detail = try selection.flatMap { try dependencies.service.detail(id: $0) } }
        catch { detail = nil; message = "无法载入生成详情。" }
    }

    private func unavailableMessage(_ title: String, _ items: [GenerationUnavailableInput]) -> String {
        let labels: [(GenerationUnavailableReason, String)] = [(.missing, "已删除"), (.archived, "已归档"), (.invalidSlot, "槽位无效"), (.incompatible, "不兼容"), (.missingResource, "图片缺失")]
        let lines = labels.compactMap { reason, label -> String? in
            let count = items.filter { $0.reason == reason }.count
            return count > 0 ? "\(label)：\(count)" : nil
        }
        return ([title + "："] + lines).joined(separator: "\n")
    }

    private func localized(_ error: any Error) -> String { (error as? LocalizedError)?.errorDescription ?? "操作失败，请稍后重试。" }
}
