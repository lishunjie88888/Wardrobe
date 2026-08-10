import XCTest
@testable import Wardrobe

final class WardrobeSmokeTests: XCTestCase {
    func testProductionEnvironmentHasApplicationName() {
        XCTAssertEqual(AppEnvironment.production().applicationName, "Wardrobe")
    }

    func testSidebarDefinesExactlyTheFivePlannedRoutes() {
        XCTAssertEqual(
            AppRoute.allCases,
            [.wardrobe, .tryOn, .outfits, .generationHistory, .settings]
        )
    }
}
