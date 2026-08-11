import Foundation

enum MockVirtualTryOnBehavior: Sendable {
    case success(delay: Duration = .zero)
    case transientFailures(count: Int, delay: Duration = .zero)
    case permanentFailure(delay: Duration = .zero)
}

actor MockVirtualTryOnProvider: VirtualTryOnProvider {
    static let providerID = ProviderID(rawValue: "mock")
    static let fixtureData = Data("wardrobe-mock-result-v1".utf8)

    nonisolated let descriptor = ProviderDescriptor(id: providerID, displayName: "Mock Preview")
    nonisolated let capabilities = VirtualTryOnCapabilities(
        maxPersonImages: 3,
        supportedPersonMediaTypes: ["image/jpeg", "image/png", "image/heic", "image/heif"],
        supportedGarmentMediaTypes: ["image/jpeg", "image/png", "image/heic", "image/heif"],
        maxImageBytes: 100 * 1_024 * 1_024,
        maxImagePixelCount: 100_000_000,
        supportedSlots: Set(TryOnSlot.allCases),
        maxGarmentsBySlot: [.upperBody: 1, .outerwear: 1, .lowerBody: 1, .footwear: 1, .accessories: 8],
        maxTotalGarments: 12,
        supportedQualities: Set(OutputQuality.allCases),
        supportedAspectRatios: Set(TryOnAspectRatio.allCases),
        supportsSeed: true,
        supportsCancellation: true,
        allowedProviderParameterKeys: ["fixture_variant"],
        maxPromptLength: 4_000
    )

    private let behavior: MockVirtualTryOnBehavior
    private var attempts = 0

    init(behavior: MockVirtualTryOnBehavior = .success()) {
        self.behavior = behavior
    }

    func validateConfiguration() async throws {}

    func generate(request: VirtualTryOnRequest) async throws -> VirtualTryOnResult {
        do {
            try VirtualTryOnRequestValidator().validate(request, against: capabilities)
            attempts += 1
            let currentAttempt = attempts
            switch behavior {
            case let .success(delay):
                try await wait(delay)
            case let .transientFailures(count, delay):
                try await wait(delay)
                if currentAttempt <= max(0, count) { throw VirtualTryOnError.transientFailure }
            case let .permanentFailure(delay):
                try await wait(delay)
                throw VirtualTryOnError.providerUnavailable
            }
            try Task.checkCancellation()
            return VirtualTryOnResult(
                imageData: Self.fixtureData,
                mediaType: "application/x-wardrobe-mock",
                providerRequestID: "mock-\(request.requestID.uuidString.lowercased())",
                providerModelID: "mock-v1",
                revisedPrompt: nil,
                metadata: ["mock": "true", "fixture": "wardrobe-mock-result-v1"]
            )
        } catch is CancellationError {
            throw VirtualTryOnError.cancelled
        }
    }

    private func wait(_ delay: Duration) async throws {
        try Task.checkCancellation()
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
    }
}
