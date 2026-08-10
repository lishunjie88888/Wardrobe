import XCTest

@MainActor
final class WardrobeLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchesAndNavigatesEverySidebarRoute() {
        let app = XCUIApplication()
        let isolatedStorageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeUITests-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment["WARDROBE_STORAGE_ROOT_OVERRIDE"] = isolatedStorageRoot.path
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: isolatedStorageRoot.path) {
                try FileManager.default.removeItem(at: isolatedStorageRoot)
            }
        }
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
