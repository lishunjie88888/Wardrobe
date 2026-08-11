import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ClothingSlotMapping: Equatable, Sendable {
    case supported(TryOnSlot)
    case unsupported
}

struct ClothingToTryOnSlotMapper: Sendable {
    func slot(for categoryCode: String, subcategoryCode _: String? = nil) -> ClothingSlotMapping {
        switch ClothingCategory(rawValue: categoryCode) {
        case .tops: .supported(.upperBody)
        case .outerwear: .supported(.outerwear)
        case .bottoms: .supported(.lowerBody)
        case .footwear: .supported(.footwear)
        case .accessories: .supported(.accessories)
        case .dresses, .other, .none: .unsupported
        }
    }
}

struct TryOnSession: Equatable, Sendable {
    var personProfileID: UUID?
    var selectedPersonImageIDs: [UUID] = []
    private(set) var garmentIDsBySlot: [TryOnSlot: [UUID]] = [:]

    var garmentCount: Int { garmentIDsBySlot.values.reduce(0) { $0 + $1.count } }

    func garmentIDs(in slot: TryOnSlot) -> [UUID] { garmentIDsBySlot[slot] ?? [] }

    mutating func selectPerson(profileID: UUID?, referenceImageIDs: [UUID]) {
        personProfileID = profileID
        selectedPersonImageIDs = referenceImageIDs
    }

    mutating func add(clothingID: UUID, to slot: TryOnSlot) {
        if slot.permitsMultipleItems {
            var values = garmentIDsBySlot[slot] ?? []
            guard !values.contains(clothingID) else { return }
            values.append(clothingID)
            garmentIDsBySlot[slot] = values
        } else {
            garmentIDsBySlot[slot] = [clothingID]
        }
    }

    mutating func remove(clothingID: UUID, from slot: TryOnSlot) {
        let remaining = (garmentIDsBySlot[slot] ?? []).filter { $0 != clothingID }
        if remaining.isEmpty { garmentIDsBySlot.removeValue(forKey: slot) }
        else { garmentIDsBySlot[slot] = remaining }
    }

    mutating func moveAccessory(fromOffsets: IndexSet, toOffset: Int) {
        var values = garmentIDsBySlot[.accessories] ?? []
        let moving = fromOffsets.sorted().map { values[$0] }
        for index in fromOffsets.sorted(by: >) { values.remove(at: index) }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        values.insert(contentsOf: moving, at: max(0, min(values.count, toOffset - removedBeforeDestination)))
        garmentIDsBySlot[.accessories] = values
    }

    mutating func clearGarments() { garmentIDsBySlot.removeAll() }

    mutating func reconcile(activeClothingIDs: Set<UUID>) {
        for slot in TryOnSlot.allCases {
            let valid = garmentIDs(in: slot).filter(activeClothingIDs.contains)
            if valid.isEmpty { garmentIDsBySlot.removeValue(forKey: slot) }
            else { garmentIDsBySlot[slot] = valid }
        }
    }
}

enum TryOnWorkspaceError: Error, Equatable, Sendable {
    case noPerson
    case personHasNoReference
    case noGarments
    case clothingUnavailable(UUID)
    case garmentResourceUnavailable(UUID)
    case personResourceUnavailable(UUID)
    case unsupportedClothing(UUID)
    case incompatibleSlot
    case referenceLimitExceeded(maximum: Int)
    case invalidImageResource
    case provider(VirtualTryOnError)
}

protocol TryOnResourceLoading: Sendable {
    func data(for resourceID: StorageResourceID) async throws -> Data
}

extension StorageService: TryOnResourceLoading {}

struct VirtualTryOnRequestBuilder: Sendable {
    private let loader: any TryOnResourceLoading
    private let promptBuilder: any TryOnPromptBuilding

    init(loader: any TryOnResourceLoading, promptBuilder: any TryOnPromptBuilding = TryOnPromptBuilder()) {
        self.loader = loader
        self.promptBuilder = promptBuilder
    }

    func build(
        session: TryOnSession,
        person: PersonReferenceSet,
        clothing: [ClothingRecord],
        capabilities: VirtualTryOnCapabilities,
        options: TryOnOptions = TryOnOptions(),
        userInstruction: String? = nil
    ) async throws -> VirtualTryOnRequest {
        guard session.personProfileID == person.profileID else { throw TryOnWorkspaceError.noPerson }
        guard !session.selectedPersonImageIDs.isEmpty else { throw TryOnWorkspaceError.personHasNoReference }
        guard session.selectedPersonImageIDs.count <= capabilities.maxPersonImages else {
            throw TryOnWorkspaceError.referenceLimitExceeded(maximum: capabilities.maxPersonImages)
        }
        guard session.garmentCount > 0 else { throw TryOnWorkspaceError.noGarments }

        let references = [person.primaryImage].compactMap { $0 } + person.additionalImages
        let referenceByID = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0) })
        var personImages: [ProviderImage] = []
        for imageID in session.selectedPersonImageIDs {
            guard let image = referenceByID[imageID] else { throw TryOnWorkspaceError.personResourceUnavailable(imageID) }
            let resource = image.processedResourceID ?? image.originalResourceID
            personImages.append(try await providerImage(id: image.id, resource: resource))
        }

        let clothingByID = Dictionary(uniqueKeysWithValues: clothing.map { ($0.id, $0) })
        var garments: [TryOnGarment] = []
        for slot in TryOnSlot.allCases {
            for (sortOrder, clothingID) in session.garmentIDs(in: slot).enumerated() {
                guard let record = clothingByID[clothingID], !record.isArchived else {
                    throw TryOnWorkspaceError.clothingUnavailable(clothingID)
                }
                guard record.processedResourceID != nil || !record.originalResourceID.rawValue.isEmpty else {
                    throw TryOnWorkspaceError.garmentResourceUnavailable(clothingID)
                }
                let resource = record.processedResourceID ?? record.originalResourceID
                garments.append(TryOnGarment(
                    clothingItemID: record.id,
                    slot: slot,
                    image: try await providerImage(id: record.id, resource: resource),
                    displayName: record.draft.name,
                    sortOrder: sortOrder
                ))
            }
        }
        let prompt = promptBuilder.build(garments: garments, userInstruction: userInstruction)
        let request = VirtualTryOnRequest(
            requestID: UUID(),
            personImages: personImages,
            garments: garments,
            prompt: prompt.text,
            promptVersion: prompt.version,
            options: options
        )
        do { try VirtualTryOnRequestValidator().validate(request, against: capabilities) }
        catch let error as VirtualTryOnError { throw TryOnWorkspaceError.provider(error) }
        return request
    }

    private func providerImage(id: UUID, resource: StorageResourceID) async throws -> ProviderImage {
        let data: Data
        do { data = try await loader.data(for: resource) }
        catch { throw TryOnWorkspaceError.invalidImageResource }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let typeIdentifier = CGImageSourceGetType(source),
              let mediaType = UTType(typeIdentifier as String)?.preferredMIMEType
        else { throw TryOnWorkspaceError.invalidImageResource }
        return ProviderImage(id: id, data: data, mediaType: mediaType, pixelWidth: width, pixelHeight: height)
    }
}
