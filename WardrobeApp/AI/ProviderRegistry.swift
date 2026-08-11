import Foundation

enum ProviderRegistryError: Error, Equatable, Sendable {
    case invalidProviderID
    case duplicateProviderID(ProviderID)
    case providerNotFound(ProviderID)
}

actor ProviderRegistry {
    private let providers: [ProviderID: any VirtualTryOnProvider]

    init(providers: [any VirtualTryOnProvider]) throws {
        var indexed: [ProviderID: any VirtualTryOnProvider] = [:]
        for provider in providers {
            let id = provider.descriptor.id
            guard (try? ProviderID(validating: id.rawValue)) == id else {
                throw ProviderRegistryError.invalidProviderID
            }
            try provider.capabilities.validateDefinition()
            guard indexed[id] == nil else { throw ProviderRegistryError.duplicateProviderID(id) }
            indexed[id] = provider
        }
        self.providers = indexed
    }

    func provider(id: ProviderID) throws -> any VirtualTryOnProvider {
        guard let provider = providers[id] else { throw ProviderRegistryError.providerNotFound(id) }
        return provider
    }

    func descriptors() -> [ProviderDescriptor] {
        providers.values.map(\.descriptor).sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
