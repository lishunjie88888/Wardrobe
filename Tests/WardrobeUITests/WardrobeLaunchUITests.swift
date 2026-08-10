import XCTest

final class WardrobeLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchesAndNavigatesEverySidebarRoute() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        for route in ["wardrobe", "tryOn", "outfits", "generationHistory", "settings"] {
            let sidebarItem = app.descendants(matching: .any)["sidebar.route.\(route)"]
            XCTAssertTrue(sidebarItem.waitForExistence(timeout: 2))
            sidebarItem.click()

            let placeholder = app.descendants(matching: .any)["placeholder.\(route)"]
            XCTAssertTrue(placeholder.waitForExistence(timeout: 2))
        }
    }
}
