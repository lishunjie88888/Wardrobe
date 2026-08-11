import Foundation

protocol StableCodeValue: RawRepresentable, Equatable, Sendable where RawValue == String {}

enum ResolvedCode<Value: StableCodeValue>: Equatable, Sendable {
    case known(Value)
    case unknown(String)

    init(_ rawValue: String) {
        if let value = Value(rawValue: rawValue) {
            self = .known(value)
        } else {
            self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case let .known(value): value.rawValue
        case let .unknown(rawValue): rawValue
        }
    }
}

enum ClothingCategory: String, CaseIterable, StableCodeValue {
    case tops
    case outerwear
    case bottoms
    case dresses
    case footwear
    case accessories
    case other
}

enum ClothingSubcategory: String, CaseIterable, StableCodeValue {
    case tshirt
    case shirt
    case sweater
    case jacket
    case coat
    case pants
    case shorts
    case skirt
    case onePiece = "one_piece"
    case sneakers
    case boots
    case bag
    case hat
    case jewelry
    case other
}

enum Season: String, CaseIterable, StableCodeValue {
    case spring
    case summer
    case autumn
    case winter
    case allSeason = "all_season"
}

enum StyleTag: String, CaseIterable, StableCodeValue {
    case casual
    case formal
    case business
    case sporty
    case street
    case minimalist
    case vintage
    case outdoor
    case other
}

enum TryOnSlot: String, CaseIterable, StableCodeValue, Codable {
    case upperBody = "upper_body"
    case outerwear
    case lowerBody = "lower_body"
    case footwear
    case accessories

    var permitsMultipleItems: Bool { self == .accessories }
}

enum GenerationStatus: String, CaseIterable, StableCodeValue {
    case queued
    case preparing
    case running
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .queued, .preparing, .running: false
        }
    }

    func canTransition(to next: GenerationStatus) -> Bool {
        switch (self, next) {
        case (.queued, .preparing), (.preparing, .running), (.running, .succeeded), (.running, .failed):
            true
        case let (current, .cancelled) where !current.isTerminal:
            true
        default:
            false
        }
    }
}
