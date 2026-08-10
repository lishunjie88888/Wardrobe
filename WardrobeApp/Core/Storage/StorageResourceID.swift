import Foundation

enum StorageOwnerKind: String, CaseIterable, Sendable {
    case garment = "garments"
    case person = "persons"
    case generation = "generations"
    case outfit = "outfits"
}

struct StorageOwner: Hashable, Sendable {
    let kind: StorageOwnerKind
    let id: UUID

    init(kind: StorageOwnerKind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    var directoryName: String { id.uuidString.lowercased() }
}

enum StorageResourceKind: Hashable, Sendable {
    case original(fileExtension: String)
    case processed
    case thumbnail
    case generationResult(fileExtension: String)
    case outfitCover

    fileprivate var fileName: String {
        switch self {
        case let .original(fileExtension):
            "original.\(fileExtension.lowercased())"
        case .processed:
            "processed.png"
        case .thumbnail:
            "thumbnail.jpg"
        case let .generationResult(fileExtension):
            "result.\(fileExtension.lowercased())"
        case .outfitCover:
            "cover.jpg"
        }
    }
}

enum StorageResourceIDError: Error, Equatable, LocalizedError {
    case empty
    case absolutePath
    case invalidComponent
    case unsupportedTopLevelDirectory
    case invalidOwnerID
    case invalidFileName
    case incompatibleResourceKind

    var errorDescription: String? {
        switch self {
        case .empty: "The storage resource ID is empty."
        case .absolutePath: "Absolute storage paths are not allowed."
        case .invalidComponent: "The storage resource ID contains an unsafe path component."
        case .unsupportedTopLevelDirectory: "The storage resource ID uses an unsupported top-level directory."
        case .invalidOwnerID: "The storage resource ID does not contain a canonical UUID owner."
        case .invalidFileName: "The storage resource ID contains an unsupported file name."
        case .incompatibleResourceKind: "The resource kind is not valid for this owner."
        }
    }
}

struct StorageResourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) throws {
        try Self.validate(rawValue)
        self.rawValue = rawValue
    }

    init(owner: StorageOwner, kind: StorageResourceKind) throws {
        try Self.validate(kind: kind, for: owner.kind)
        try self.init(rawValue: "\(owner.kind.rawValue)/\(owner.directoryName)/\(kind.fileName)")
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var owner: StorageOwner {
        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        return StorageOwner(
            kind: StorageOwnerKind(rawValue: String(components[0]))!,
            id: UUID(uuidString: String(components[1]))!
        )
    }

    private static func validate(_ rawValue: String) throws {
        guard !rawValue.isEmpty else { throw StorageResourceIDError.empty }
        guard !rawValue.hasPrefix("/"), !NSString(string: rawValue).isAbsolutePath else {
            throw StorageResourceIDError.absolutePath
        }
        guard !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw StorageResourceIDError.invalidComponent
        }

        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw StorageResourceIDError.invalidComponent
        }
        guard let ownerKind = StorageOwnerKind(rawValue: components[0]) else {
            throw StorageResourceIDError.unsupportedTopLevelDirectory
        }
        guard let ownerID = UUID(uuidString: components[1]),
              ownerID.uuidString.lowercased() == components[1]
        else {
            throw StorageResourceIDError.invalidOwnerID
        }
        guard validFileName(components[2], for: ownerKind) else {
            throw StorageResourceIDError.invalidFileName
        }
    }

    private static func validate(kind: StorageResourceKind, for ownerKind: StorageOwnerKind) throws {
        switch (ownerKind, kind) {
        case (.garment, .original), (.garment, .processed), (.garment, .thumbnail),
             (.person, .original), (.person, .processed), (.person, .thumbnail),
             (.generation, .generationResult), (.generation, .thumbnail),
             (.outfit, .outfitCover):
            return
        default:
            throw StorageResourceIDError.incompatibleResourceKind
        }
    }

    private static func validFileName(_ fileName: String, for ownerKind: StorageOwnerKind) -> Bool {
        let supportedOriginalExtensions = ["jpg", "jpeg", "png", "heic", "heif"]
        switch ownerKind {
        case .garment, .person:
            if fileName == "processed.png" || fileName == "thumbnail.jpg" { return true }
            guard fileName.hasPrefix("original.") else { return false }
            return supportedOriginalExtensions.contains(String(fileName.dropFirst("original.".count)))
        case .generation:
            if fileName == "thumbnail.jpg" { return true }
            guard fileName.hasPrefix("result.") else { return false }
            return supportedOriginalExtensions.contains(String(fileName.dropFirst("result.".count)))
        case .outfit:
            return fileName == "cover.jpg"
        }
    }
}
