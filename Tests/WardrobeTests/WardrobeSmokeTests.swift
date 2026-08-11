import XCTest
@testable import Wardrobe

@MainActor
final class WardrobeSmokeTests: XCTestCase {
    func testEnvironmentHasApplicationName() throws {
        let container = try WardrobeModelContainerFactory.inMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeSmokeTests-\(UUID().uuidString)", isDirectory: true)
        let storage = try StorageService(configuration: StorageConfiguration(rootURL: root))
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(
            applicationName: "Wardrobe",
            modelContainer: container,
            storageService: storage,
            imageProcessingService: ImageProcessingService(storage: storage)
        )
        XCTAssertEqual(environment.applicationName, "Wardrobe")
    }

    func testSidebarDefinesExactlyTheSixPlannedRoutes() {
        XCTAssertEqual(
            AppRoute.allCases,
            [.wardrobe, .person, .tryOn, .outfits, .generationHistory, .settings]
        )
    }
}
