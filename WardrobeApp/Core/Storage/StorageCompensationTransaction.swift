import Foundation

enum StorageCompensationAction: Sendable {
    case deleteResource(StorageResourceID)
    case deleteResourceDirectory(StorageOwner)
}

struct StorageCleanupIssue: Equatable, Sendable {
    let actionDescription: String
    let errorDescription: String
}

/// Records only resources created by one cross-database/filesystem operation.
/// A coordinating service commits after its Repository save succeeds, or calls
/// rollback after a failure. Rollback never broad-scans the library.
actor StorageCompensationTransaction {
    private let storage: any StorageServing
    private var actions: [StorageCompensationAction] = []
    private var isFinished = false

    init(storage: any StorageServing) {
        self.storage = storage
    }

    func register(_ action: StorageCompensationAction) {
        guard !isFinished else { return }
        actions.append(action)
    }

    func commit() {
        isFinished = true
        actions.removeAll(keepingCapacity: false)
    }

    func rollback() async -> [StorageCleanupIssue] {
        guard !isFinished else { return [] }
        isFinished = true
        var issues: [StorageCleanupIssue] = []
        for action in actions.reversed() {
            do {
                switch action {
                case let .deleteResource(resourceID):
                    try await storage.delete(resourceID)
                case let .deleteResourceDirectory(owner):
                    try await storage.deleteResourceDirectory(for: owner)
                }
            } catch {
                issues.append(
                    StorageCleanupIssue(
                        actionDescription: String(describing: action),
                        errorDescription: error.localizedDescription
                    )
                )
            }
        }
        actions.removeAll(keepingCapacity: false)
        return issues
    }
}
