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
        let environment = AppEnvironment(
            applicationName: "Wardrobe",
            modelContainer: container,
            storageService: storage
        )
        XCTAssertEqual(environment.applicationName, "Wardrobe")
    }

    func testSidebarDefinesExactlyTheFivePlannedRoutes() {
        XCTAssertEqual(
            AppRoute.allCases,
            [.wardrobe, .tryOn, .outfits, .generationHistory, .settings]
        )
    }
}
