import Foundation

protocol VirtualTryOnProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    var capabilities: VirtualTryOnCapabilities { get }

    func validateConfiguration() async throws
    func generate(request: VirtualTryOnRequest) async throws -> VirtualTryOnResult
}

enum VirtualTryOnInputViolation: String, Equatable, Sendable {
    case noPersonImages
    case noGarments
    case emptyPrompt
    case unsupportedOptionsVersion
    case duplicateImageID
    case duplicateGarmentID
    case emptyImageData
    case invalidImageDimensions
    case unsupportedPersonMediaType
    case unsupportedGarmentMediaType
    case tooManyPersonImages
    case imageTooLarge
    case imagePixelCountTooLarge
    case unsupportedSlot
    case slotLimitExceeded
    case totalGarmentLimitExceeded
    case unsupportedQuality
    case unsupportedAspectRatio
    case unsupportedSeed
    case unsupportedProviderParameter
    case promptTooLong
}

enum VirtualTryOnError: Error, Equatable, Sendable {
    case invalidInput(VirtualTryOnInputViolation)
    case unsupportedCapability(VirtualTryOnInputViolation)
    case configurationUnavailable
    case transientFailure
    case providerUnavailable
    case invalidResponse
    case cancelled
}

struct VirtualTryOnRequestValidator: Sendable {
    func validate(_ request: VirtualTryOnRequest, against capabilities: VirtualTryOnCapabilities) throws {
        try capabilities.validateDefinition()
        guard !request.personImages.isEmpty else { throw VirtualTryOnError.invalidInput(.noPersonImages) }
        guard !request.garments.isEmpty else { throw VirtualTryOnError.invalidInput(.noGarments) }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VirtualTryOnError.invalidInput(.emptyPrompt)
        }
        guard request.options.schemaVersion == TryOnOptions.currentSchemaVersion else {
            throw VirtualTryOnError.invalidInput(.unsupportedOptionsVersion)
        }
        guard request.prompt.count <= capabilities.maxPromptLength else {
            throw VirtualTryOnError.unsupportedCapability(.promptTooLong)
        }
        guard request.personImages.count <= capabilities.maxPersonImages else {
            throw VirtualTryOnError.unsupportedCapability(.tooManyPersonImages)
        }
        guard request.garments.count <= capabilities.maxTotalGarments else {
            throw VirtualTryOnError.unsupportedCapability(.totalGarmentLimitExceeded)
        }
        guard capabilities.supportedQualities.contains(request.options.quality) else {
            throw VirtualTryOnError.unsupportedCapability(.unsupportedQuality)
        }
        guard capabilities.supportedAspectRatios.contains(request.options.aspectRatio) else {
            throw VirtualTryOnError.unsupportedCapability(.unsupportedAspectRatio)
        }
        if request.options.seed != nil, !capabilities.supportsSeed {
            throw VirtualTryOnError.unsupportedCapability(.unsupportedSeed)
        }
        guard Set(request.options.providerParameters.keys).isSubset(of: capabilities.allowedProviderParameterKeys) else {
            throw VirtualTryOnError.unsupportedCapability(.unsupportedProviderParameter)
        }

        let allImages = request.personImages + request.garments.map(\.image)
        guard Set(allImages.map(\.id)).count == allImages.count else {
            throw VirtualTryOnError.invalidInput(.duplicateImageID)
        }
        try request.personImages.forEach {
            try validateImage($0, supportedMediaTypes: capabilities.supportedPersonMediaTypes, capabilities: capabilities, unsupported: .unsupportedPersonMediaType)
        }
        try request.garments.forEach {
            try validateImage($0.image, supportedMediaTypes: capabilities.supportedGarmentMediaTypes, capabilities: capabilities, unsupported: .unsupportedGarmentMediaType)
        }

        guard Set(request.garments.map(\.clothingItemID)).count == request.garments.count else {
            throw VirtualTryOnError.invalidInput(.duplicateGarmentID)
        }
        let grouped = Dictionary(grouping: request.garments, by: \.slot)
        for (slot, garments) in grouped {
            guard capabilities.supportedSlots.contains(slot) else {
                throw VirtualTryOnError.unsupportedCapability(.unsupportedSlot)
            }
            guard garments.count <= (capabilities.maxGarmentsBySlot[slot] ?? 0) else {
                throw VirtualTryOnError.unsupportedCapability(.slotLimitExceeded)
            }
        }
    }

    private func validateImage(
        _ image: ProviderImage,
        supportedMediaTypes: Set<String>,
        capabilities: VirtualTryOnCapabilities,
        unsupported: VirtualTryOnInputViolation
    ) throws {
        guard !image.data.isEmpty else { throw VirtualTryOnError.invalidInput(.emptyImageData) }
        guard image.pixelWidth > 0, image.pixelHeight > 0 else {
            throw VirtualTryOnError.invalidInput(.invalidImageDimensions)
        }
        guard supportedMediaTypes.contains(image.mediaType) else {
            throw VirtualTryOnError.unsupportedCapability(unsupported)
        }
        guard image.data.count <= capabilities.maxImageBytes else {
            throw VirtualTryOnError.unsupportedCapability(.imageTooLarge)
        }
        let (pixelCount, overflow) = image.pixelWidth.multipliedReportingOverflow(by: image.pixelHeight)
        guard !overflow, pixelCount <= capabilities.maxImagePixelCount else {
            throw VirtualTryOnError.unsupportedCapability(.imagePixelCountTooLarge)
        }
    }
}

extension VirtualTryOnCapabilities {
    func validateDefinition() throws {
        guard maxPersonImages > 0,
              maxImageBytes > 0,
              maxImagePixelCount > 0,
              maxTotalGarments > 0,
              maxPromptLength > 0,
              !supportedPersonMediaTypes.isEmpty,
              !supportedGarmentMediaTypes.isEmpty,
              !supportedSlots.isEmpty,
              !supportedQualities.isEmpty,
              !supportedAspectRatios.isEmpty,
              supportedPersonMediaTypes.allSatisfy({ $0 == $0.lowercased() && $0.hasPrefix("image/") }),
              supportedGarmentMediaTypes.allSatisfy({ $0 == $0.lowercased() && $0.hasPrefix("image/") }),
              Set(maxGarmentsBySlot.keys) == supportedSlots,
              maxGarmentsBySlot.values.allSatisfy({ $0 > 0 })
        else {
            throw VirtualTryOnError.configurationUnavailable
        }
    }
}

struct TryOnPrompt: Equatable, Sendable {
    let text: String
    let version: String
}

protocol TryOnPromptBuilding: Sendable {
    func build(garments: [TryOnGarment], userInstruction: String?) -> TryOnPrompt
}

struct TryOnPromptBuilder: TryOnPromptBuilding {
    static let version = "wardrobe-try-on-prompt-v1"

    func build(garments: [TryOnGarment], userInstruction: String? = nil) -> TryOnPrompt {
        let summary = garments
            .sorted {
                ($0.slot.rawValue, $0.sortOrder, $0.clothingItemID.uuidString) <
                ($1.slot.rawValue, $1.sortOrder, $1.clothingItemID.uuidString)
            }
            .map { "\($0.slot.rawValue): \($0.displayName)" }
            .joined(separator: "; ")
        let instruction = userInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = instruction.flatMap { $0.isEmpty ? nil : $0 }.map { " Additional instruction: \($0)" } ?? ""
        return TryOnPrompt(
            text: "Create a virtual try-on preview using these semantic garment slots: \(summary). Preserve the person's identity and pose.\(suffix)",
            version: Self.version
        )
    }
}
