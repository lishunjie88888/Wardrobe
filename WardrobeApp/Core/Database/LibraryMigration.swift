import Foundation
import SwiftData

struct LibraryVersionDescriptor: Codable, Equatable, Sendable, CustomStringConvertible {
    let schemaVersion: Schema.Version
    let storageLayoutVersion: Int

    static let current = LibraryVersionDescriptor(
        schemaVersion: WardrobeSchemaV1.versionIdentifier,
        storageLayoutVersion: StorageConfiguration.layoutVersion
    )

    var description: String {
        "schema \(schemaVersion.description), storage layout \(storageLayoutVersion)"
    }
}

enum WardrobeSchemaRegistry {
    static let current = WardrobeSchemaV1.versionIdentifier
    static let supported = [WardrobeSchemaV1.versionIdentifier]

    static func hasMigrationPath(from version: Schema.Version) -> Bool {
        version == current || (supported.contains(version) && version < current)
    }
}

struct LibraryMigrationCheckpoint: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case transforming
        case validating
        case committing
    }

    let source: LibraryVersionDescriptor
    let target: LibraryVersionDescriptor
    let phase: Phase
}

enum MigrationPreflightResult: Equatable, Sendable {
    case current
    case migrationRequired(from: LibraryVersionDescriptor, to: LibraryVersionDescriptor)
    case unsupportedFutureSchema(Schema.Version)
    case unsupportedStorageLayout(Int)
    case noMigrationPath(Schema.Version)
    case invalidManifest
    case interruptedMigration(LibraryMigrationCheckpoint)
}

struct MigrationPreflight: Sendable {
    let current: LibraryVersionDescriptor
    let supportedSchemas: [Schema.Version]

    init(
        current: LibraryVersionDescriptor = .current,
        supportedSchemas: [Schema.Version] = WardrobeSchemaRegistry.supported
    ) {
        self.current = current
        self.supportedSchemas = supportedSchemas
    }

    func evaluate(
        manifest: StorageLibraryManifest?,
        schemaVersion: Schema.Version?,
        checkpoint: LibraryMigrationCheckpoint?
    ) -> MigrationPreflightResult {
        if let checkpoint { return .interruptedMigration(checkpoint) }
        guard let manifest, let schemaVersion, manifest.storageLayoutVersion > 0 else {
            return .invalidManifest
        }
        if schemaVersion > current.schemaVersion {
            return .unsupportedFutureSchema(schemaVersion)
        }
        if manifest.storageLayoutVersion > current.storageLayoutVersion {
            return .unsupportedStorageLayout(manifest.storageLayoutVersion)
        }
        if schemaVersion < current.schemaVersion && !supportedSchemas.contains(schemaVersion) {
            return .noMigrationPath(schemaVersion)
        }
        let source = LibraryVersionDescriptor(
            schemaVersion: schemaVersion,
            storageLayoutVersion: manifest.storageLayoutVersion
        )
        return source == current ? .current : .migrationRequired(from: source, to: current)
    }
}

enum LibraryMigrationError: Error, Equatable, LocalizedError {
    case blocked
    case migrationFailed
    case validationFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .blocked: "This library cannot be opened safely."
        case .migrationFailed: "The library migration failed."
        case .validationFailed: "The migrated library did not pass consistency validation."
        case .rollbackFailed: "The library migration failed and recovery could not be verified."
        }
    }
}

protocol StorageMigrationStep: Sendable {
    func transform() async throws
    func validate() async throws
    func commit() async throws
    func rollback() async throws
}

actor LibraryMigrationCoordinator {
    private let checkpointURL: URL

    init(checkpointURL: URL) {
        self.checkpointURL = checkpointURL
    }

    func checkpoint() throws -> LibraryMigrationCheckpoint? {
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(
                LibraryMigrationCheckpoint.self,
                from: Data(contentsOf: checkpointURL)
            )
        } catch {
            throw LibraryMigrationError.blocked
        }
    }

    func migrate(
        from source: LibraryVersionDescriptor,
        to target: LibraryVersionDescriptor,
        step: any StorageMigrationStep
    ) async throws {
        try writeCheckpoint(.init(source: source, target: target, phase: .prepared))
        do {
            try writeCheckpoint(.init(source: source, target: target, phase: .transforming))
            try await step.transform()
            try writeCheckpoint(.init(source: source, target: target, phase: .validating))
            try await step.validate()
            try writeCheckpoint(.init(source: source, target: target, phase: .committing))
            try await step.commit()
            try FileManager.default.removeItem(at: checkpointURL)
        } catch {
            do {
                try await step.rollback()
                if FileManager.default.fileExists(atPath: checkpointURL.path) {
                    try FileManager.default.removeItem(at: checkpointURL)
                }
            } catch {
                throw LibraryMigrationError.rollbackFailed
            }
            throw LibraryMigrationError.migrationFailed
        }
    }

    private func writeCheckpoint(_ checkpoint: LibraryMigrationCheckpoint) throws {
        let parent = checkpointURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(checkpoint).write(to: checkpointURL, options: .atomic)
    }
}

struct LibraryConsistencyIssue: Equatable, Sendable {
    enum Kind: String, Sendable {
        case duplicateID
        case multipleDefaultPersons
        case archivedDefaultPerson
        case multiplePrimaryImages
        case invalidOutfitSlot
        case invalidAccessoryOrder
        case invalidGenerationSlot
        case invalidResourceID
    }

    let kind: Kind
    let recordID: UUID?
}

@MainActor
struct LibraryConsistencyValidator {
    func validate(container: ModelContainer) throws -> [LibraryConsistencyIssue] {
        let context = ModelContext(container)
        var issues: [LibraryConsistencyIssue] = []
        let clothing = try context.fetch(FetchDescriptor<ClothingItem>())
        let persons = try context.fetch(FetchDescriptor<PersonProfile>())
        let images = try context.fetch(FetchDescriptor<PersonImage>())
        let outfits = try context.fetch(FetchDescriptor<Outfit>())
        let outfitItems = try context.fetch(FetchDescriptor<OutfitItem>())
        let generations = try context.fetch(FetchDescriptor<GenerationRecord>())
        let personInputs = try context.fetch(FetchDescriptor<GenerationPersonInput>())
        let garmentInputs = try context.fetch(FetchDescriptor<GenerationGarmentInput>())

        let ids = clothing.map(\.id) + persons.map(\.id) + images.map(\.id)
            + outfits.map(\.id) + outfitItems.map(\.id) + generations.map(\.id)
            + personInputs.map(\.id) + garmentInputs.map(\.id)
        for id in Set(ids) where ids.filter({ $0 == id }).count > 1 {
            issues.append(.init(kind: .duplicateID, recordID: id))
        }
        let defaults = persons.filter { $0.isDefault }
        if defaults.count > 1 { issues.append(.init(kind: .multipleDefaultPersons, recordID: nil)) }
        for person in defaults where person.archivedAt != nil {
            issues.append(.init(kind: .archivedDefaultPerson, recordID: person.id))
        }
        for person in persons where person.images.filter(\.isPrimary).count > 1 {
            issues.append(.init(kind: .multiplePrimaryImages, recordID: person.id))
        }
        for outfit in outfits {
            let groups = Dictionary(grouping: outfit.items, by: \.slotCode)
            for (slot, items) in groups where slot != TryOnSlot.accessories.rawValue && items.count > 1 {
                issues.append(.init(kind: .invalidOutfitSlot, recordID: outfit.id))
            }
            if let accessories = groups[TryOnSlot.accessories.rawValue] {
                let orders = accessories.map(\.sortOrder).sorted()
                if orders != Array(0..<orders.count) {
                    issues.append(.init(kind: .invalidAccessoryOrder, recordID: outfit.id))
                }
            }
        }
        for generation in generations {
            let groups = Dictionary(grouping: generation.garmentInputs, by: \.slotCode)
            if groups.contains(where: { $0.key != TryOnSlot.accessories.rawValue && $0.value.count > 1 }) {
                issues.append(.init(kind: .invalidGenerationSlot, recordID: generation.id))
            }
        }
        let resourcePairs: [(UUID, String)] =
            clothing.flatMap { item in
                [item.originalResourceID, item.processedResourceID, item.thumbnailResourceID]
                    .compactMap { $0 }.map { (item.id, $0) }
            } + images.flatMap { image in
                [image.originalResourceID, image.processedResourceID, image.thumbnailResourceID]
                    .compactMap { $0 }.map { (image.id, $0) }
            } + outfitItems.compactMap { item in item.thumbnailResourceIDSnapshot.map { (item.id, $0) } }
            + generations.flatMap { record in
                [record.resultResourceID, record.resultThumbnailResourceID]
                    .compactMap { $0 }.map { (record.id, $0) }
            } + personInputs.map { ($0.id, $0.resourceIDSnapshot) }
            + garmentInputs.map { ($0.id, $0.resourceIDSnapshot) }
        for (id, rawValue) in resourcePairs where (try? StorageResourceID(rawValue: rawValue)) == nil {
            issues.append(.init(kind: .invalidResourceID, recordID: id))
        }
        return issues
    }
}
