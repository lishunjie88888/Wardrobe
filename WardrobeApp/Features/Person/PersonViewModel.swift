import Foundation
import Observation

struct PersonFeatureDependencies {
    let management: PersonManagementService
    let importer: ImportPersonImageService
    let imageDeletion: PersonImageDeletionService
    let profileDeletion: PersonProfileDeletionService
    let imageLoader: any PersonImageLoading
}

@MainActor
@Observable
final class PersonViewModel {
    enum ContentState: Equatable {
        case loading
        case empty
        case content
        case error(String)
    }

    private let dependencies: PersonFeatureDependencies
    private var importTask: Task<Void, Never>?

    var profiles: [PersonProfileRecord] = []
    var archiveFilter: PersonArchiveFilter = .active
    var state: ContentState = .loading
    var selectedID: UUID?
    var isImporting = false
    var presentedError: String?
    var cleanupNotice: String?

    init(dependencies: PersonFeatureDependencies) { self.dependencies = dependencies }

    var selectedProfile: PersonProfileRecord? { profiles.first { $0.id == selectedID } }
    var imageLoader: any PersonImageLoading { dependencies.imageLoader }

    func load() {
        do {
            profiles = try dependencies.management.profiles(archive: archiveFilter)
#if DEBUG
            if selectedID == nil,
               let rawID = ProcessInfo.processInfo.environment["WARDROBE_UI_TEST_SELECT_PERSON"],
               let id = UUID(uuidString: rawID), profiles.contains(where: { $0.id == id }) {
                selectedID = id
            }
#endif
            if let selectedID, !profiles.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            if selectedID == nil { selectedID = profiles.first?.id }
            state = profiles.isEmpty ? .empty : .content
        } catch {
            state = .error("无法读取人物资料，请稍后重试。")
        }
    }

    @discardableResult
    func create(draft: PersonDraft) -> Bool {
        do {
            let profile = try dependencies.management.create(draft: draft)
            load(); selectedID = profile.id
            return true
        } catch {
            presentedError = Self.userMessage(for: error)
            return false
        }
    }

    @discardableResult
    func update(id: UUID, draft: PersonDraft) -> Bool {
        do {
            _ = try dependencies.management.update(id: id, draft: draft)
            load(); selectedID = id
            return true
        } catch {
            presentedError = Self.userMessage(for: error)
            return false
        }
    }

    func setDefault(profileID: UUID) {
        do { try dependencies.management.setDefault(id: profileID); load(); selectedID = profileID }
        catch { presentedError = "无法设置默认人物，请重试。" }
    }

    func setPrimary(imageID: UUID, profileID: UUID) {
        do { try dependencies.management.setPrimary(imageID: imageID, profileID: profileID); load(); selectedID = profileID }
        catch { presentedError = "无法设置主图，请重试。" }
    }

    func setArchived(profileID: UUID, value: Bool) {
        do { _ = try dependencies.management.setArchived(id: profileID, value: value); load() }
        catch { presentedError = value ? "无法归档人物，请重试。" : "无法恢复人物，请重试。" }
    }

    func importImage(from url: URL, profileID: UUID) {
        guard !isImporting else { return }
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { isImporting = false }
            do {
                _ = try await dependencies.importer.importImage(from: url, profileID: profileID)
                load(); selectedID = profileID
            } catch is CancellationError {
                return
            } catch let failure as PersonServiceFailure {
                presentedError = Self.userMessage(for: failure.primaryError)
                if !failure.cleanupIssues.isEmpty { cleanupNotice = "导入未完成，且部分临时文件稍后需要清理。" }
            } catch {
                presentedError = Self.userMessage(for: error)
            }
        }
    }

    func cancelImport() { importTask?.cancel() }

    func imageDeleteImpact(imageID: UUID) -> PersonImageDeleteImpact? {
        do { return try dependencies.imageDeletion.impact(for: imageID) }
        catch { presentedError = "无法分析图片删除影响。为保护历史资源，本次未删除。"; return nil }
    }

    func profileDeleteImpact(profileID: UUID) -> PersonProfileDeleteImpact? {
        do { return try dependencies.profileDeletion.impact(for: profileID) }
        catch { presentedError = "无法分析人物删除影响。为保护历史资源，本次未删除。"; return nil }
    }

    func deleteImage(_ image: PersonImageRecord) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await dependencies.imageDeletion.permanentlyDelete(imageID: image.id)
                load(); selectedID = image.profileID
                presentCleanupResult(result, noun: "图片")
            } catch { presentedError = "删除图片失败，人物资料和历史记录未受影响。" }
        }
    }

    func deleteProfile(_ profile: PersonProfileRecord) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await dependencies.profileDeletion.permanentlyDelete(profileID: profile.id)
                selectedID = nil; load()
                presentCleanupResult(result, noun: "人物记录")
            } catch { presentedError = "永久删除失败，其他人物和历史记录未受影响。" }
        }
    }

    private func presentCleanupResult(_ result: PersonDeletionResult, noun: String) {
        if !result.cleanupIssues.isEmpty { cleanupNotice = "\(noun)已删除，但部分无引用文件清理失败，稍后可安全重试。" }
        else if !result.retainedResources.isEmpty { cleanupNotice = "\(noun)已删除；生成历史仍引用的图片已安全保留。" }
    }

    private static func userMessage(for error: any Error) -> String {
        if error is PersonValidationError { return error.localizedDescription }
        if error is ImageProcessingError { return "图片处理失败，请确认图片可正常打开后重试。" }
        if error is StorageError || error is ImageValidationError { return "无法读取或保存图片，请检查格式、大小与磁盘空间。" }
        return "保存人物资料失败，请稍后重试。"
    }
}
