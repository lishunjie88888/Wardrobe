import Foundation
import Observation

@MainActor
@Observable
final class TryOnWorkspaceCoordinator {
    private(set) var pendingRequest: OutfitLoadResult?
    private(set) var pendingRegenerateRequest: GenerationRegenerateRequest?

    func requestLoad(_ result: OutfitLoadResult) { pendingRequest = result }

    func consumeRequest() -> OutfitLoadResult? {
        defer { pendingRequest = nil }
        return pendingRequest
    }

    func requestRegenerate(_ request: GenerationRegenerateRequest) { pendingRegenerateRequest = request }

    func consumeRegenerateRequest() -> GenerationRegenerateRequest? {
        defer { pendingRegenerateRequest = nil }
        return pendingRegenerateRequest
    }
}
