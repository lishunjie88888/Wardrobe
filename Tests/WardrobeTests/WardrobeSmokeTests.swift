import XCTest
@testable import Wardrobe

@MainActor
final class WardrobeSmokeTests: XCTestCase {
    func testEnvironmentHasApplicationName() throws {
        let container = try WardrobeModelContainerFactory.inMemory()
        let environment = AppEnvironment(applicationName: "Wardrobe", modelContainer: container)
        XCTAssertEqual(environment.applicationName, "Wardrobe")
    }

    func testSidebarDefinesExactlyTheFivePlannedRoutes() {
        XCTAssertEqual(
            AppRoute.allCases,
            [.wardrobe, .tryOn, .outfits, .generationHistory, .settings]
        )
    }
}
