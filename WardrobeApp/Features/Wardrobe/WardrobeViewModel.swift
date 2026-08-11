import Foundation
import Observation

@MainActor
@Observable
final class WardrobeViewModel {
    enum ContentState: Equatable {
        case loading
        case empty
        case filteredEmpty
        case content
        case error(String)
    }

    private let dependencies: WardrobeFeatureDependencies
    private var searchTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?

    var items: [ClothingRecord] = []
    var query = ClothingQuery()
    var state: ContentState = .loading
    var selectedID: UUID?
    var isImporting = false
    var presentedError: String?
    var cleanupNotice: String?

    init(dependencies: WardrobeFeatureDependencies) { self.dependencies = dependencies }

    var selectedItem: ClothingRecord? { items.first { $0.id == selectedID } }
    var imageLoader: any ClothingImageLoading { dependencies.imageLoader }

    func load() {
        do {
            items = try dependencies.management.clothing(matching: query)
#if DEBUG
            if selectedID == nil,
               let rawID = ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_SELECT_CLOTHING"],
               let requestedID = UUID(uuidString: rawID),
               items.contains(where: { $0.id == requestedID }) {
                selectedID = requestedID
            }
#endif
            if let selectedID, !items.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            state = items.isEmpty ? (query.hasActiveFilters ? .filteredEmpty : .empty) : .content
        } catch {
            state = .error("无法读取衣橱，请稍后重试。")
        }
    }

    func searchChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.load()
        }
    }

    func filtersChanged() { load() }

    func clearFilters() {
        query = ClothingQuery()
        load()
    }

    func importClothing(from url: URL, draft: ClothingDraft) {
        guard !isImporting else { return }
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { isImporting = false }
            do {
                let record = try await dependencies.importer.importClothing(from: url, draft: draft)
                load()
                selectedID = record.id
            } catch is CancellationError {
                return
            } catch let failure as ClothingServiceFailure {
                presentedError = Self.userMessage(for: failure.primaryError)
                if !failure.cleanupIssues.isEmpty {
                    cleanupNotice = "导入未完成，且部分临时文件稍后需要清理。原始错误已保留。"
                }
            } catch {
                presentedError = Self.userMessage(for: error)
            }
        }
    }

    func cancelImport() { importTask?.cancel() }

    func update(id: UUID, draft: ClothingDraft) -> Bool {
        do {
            _ = try dependencies.management.update(id: id, draft: draft)
            load()
            selectedID = id
            return true
        } catch {
            presentedError = Self.userMessage(for: error)
            return false
        }
    }

    func toggleFavorite(_ item: ClothingRecord) {
        do {
            _ = try dependencies.management.setFavorite(id: item.id, value: !item.draft.isFavorite)
            load()
            selectedID = item.id
        } catch { presentedError = "无法更新收藏状态，请重试。" }
    }

    func setArchived(_ item: ClothingRecord, value: Bool) {
        do {
            _ = try dependencies.management.setArchived(id: item.id, value: value)
            load()
        } catch { presentedError = value ? "无法归档衣物，请重试。" : "无法恢复衣物，请重试。" }
    }

    func deleteImpact(for item: ClothingRecord) -> ClothingDeleteImpact? {
        do { return try dependencies.deletion.impact(for: item.id) }
        catch {
            presentedError = "无法分析删除影响。为保护历史资源，本次未执行删除。"
            return nil
        }
    }

    func permanentlyDelete(_ item: ClothingRecord) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await dependencies.deletion.permanentlyDelete(clothingID: item.id)
                selectedID = nil
                load()
                if !result.cleanupIssues.isEmpty {
                    cleanupNotice = "衣物记录已删除，但部分无引用文件清理失败，稍后可安全重试。"
                } else if !result.retainedResources.isEmpty {
                    cleanupNotice = "衣物记录已删除；历史穿搭或生成记录仍引用的图片已安全保留。"
                }
            } catch {
                presentedError = "永久删除失败，其他衣物和历史记录未受影响。"
            }
        }
    }

    private static func userMessage(for error: any Error) -> String {
        if error is ClothingValidationError { return error.localizedDescription }
        if error is ImageProcessingError { return "图片处理失败，请确认图片可正常打开后重试。" }
        if error is StorageError || error is ImageValidationError { return "无法读取或保存图片，请检查文件格式与磁盘空间。" }
        return "保存衣物失败，请稍后重试。"
    }
}
