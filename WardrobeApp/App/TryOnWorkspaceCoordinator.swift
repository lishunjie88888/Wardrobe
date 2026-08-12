import Foundation
import Observation

@MainActor
@Observable
final class TryOnWorkspaceCoordinator {
    private(set) var pendingRequest: OutfitLoadResult?

    func requestLoad(_ result: OutfitLoadResult) { pendingRequest = result }

    func consumeRequest() -> OutfitLoadResult? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}
