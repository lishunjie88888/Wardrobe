import Foundation

struct ProviderID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(validating rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy(allowed.contains),
              normalized == rawValue
        else {
            throw ProviderRegistryError.invalidProviderID
        }
        self.rawValue = normalized
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(validating: rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Provider ID is not a valid stable identifier."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum OutputQuality: String, CaseIterable, Codable, Sendable {
    case standard
    case high
}

enum TryOnAspectRatio: String, CaseIterable, Codable, Sendable {
    case original
    case square
    case portrait
    case landscape
}

indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null
}

struct TryOnOptions: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let quality: OutputQuality
    let aspectRatio: TryOnAspectRatio
    let seed: Int?
    let providerParameters: [String: JSONValue]

    init(
        schemaVersion: Int = currentSchemaVersion,
        quality: OutputQuality = .standard,
        aspectRatio: TryOnAspectRatio = .original,
        seed: Int? = nil,
        providerParameters: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.quality = quality
        self.aspectRatio = aspectRatio
        self.seed = seed
        self.providerParameters = providerParameters
    }
}

struct ProviderImage: Codable, Equatable, Sendable {
    let id: UUID
    let data: Data
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int

    init(id: UUID, data: Data, mediaType: String, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.data = data
        self.mediaType = mediaType.lowercased()
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

struct TryOnGarment: Codable, Equatable, Sendable {
    let clothingItemID: UUID
    let slot: TryOnSlot
    let image: ProviderImage
    let displayName: String
    let sortOrder: Int

    init(
        clothingItemID: UUID,
        slot: TryOnSlot,
        image: ProviderImage,
        displayName: String,
        sortOrder: Int = 0
    ) {
        self.clothingItemID = clothingItemID
        self.slot = slot
        self.image = image
        self.displayName = displayName
        self.sortOrder = sortOrder
    }
}

struct VirtualTryOnRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let personImages: [ProviderImage]
    let garments: [TryOnGarment]
    let prompt: String
    let promptVersion: String
    let options: TryOnOptions
}

struct VirtualTryOnResult: Codable, Equatable, Sendable {
    let imageData: Data
    let mediaType: String
    let providerRequestID: String?
    let providerModelID: String?
    let revisedPrompt: String?
    let metadata: [String: String]
}

struct ProviderDescriptor: Equatable, Sendable {
    let id: ProviderID
    let displayName: String
}

struct VirtualTryOnCapabilities: Equatable, Sendable {
    let maxPersonImages: Int
    let supportedPersonMediaTypes: Set<String>
    let supportedGarmentMediaTypes: Set<String>
    let maxImageBytes: Int
    let maxImagePixelCount: Int
    let supportedSlots: Set<TryOnSlot>
    let maxGarmentsBySlot: [TryOnSlot: Int]
    let maxTotalGarments: Int
    let supportedQualities: Set<OutputQuality>
    let supportedAspectRatios: Set<TryOnAspectRatio>
    let supportsSeed: Bool
    let supportsCancellation: Bool
    let allowedProviderParameterKeys: Set<String>
    let maxPromptLength: Int
}
