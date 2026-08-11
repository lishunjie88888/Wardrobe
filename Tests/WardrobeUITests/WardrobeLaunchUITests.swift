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

            if route == "wardrobe" {
                XCTAssertTrue(app.staticTexts["我的衣橱"].waitForExistence(timeout: 2))
            } else {
                XCTAssertTrue(app.descendants(matching: .any)["placeholder.\(route)"].waitForExistence(timeout: 2))
            }
        }
    }

    func testInjectedClothingCanBeEditedFavoritedAndArchived() {
        let app = XCUIApplication()
        let isolatedStorageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeUIFlow-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment["WARDROBE_STORAGE_ROOT_OVERRIDE"] = isolatedStorageRoot.path
        app.launchEnvironment["WARDROBE_UI_TEST_SEED_CLOTHING"] = "1"
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: isolatedStorageRoot.path) {
                try FileManager.default.removeItem(at: isolatedStorageRoot)
            }
        }
        app.launch()

        let card = app.descendants(matching: .any)["wardrobe.item.00000000-0000-0000-0000-000000000404"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.click()
        let favorite = app.buttons["wardrobe.detail.favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        favorite.click()
        let edit = app.buttons["wardrobe.detail.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 2))
        edit.click()
        let name = app.descendants(matching: .any)["wardrobe.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("已编辑的外套")
        app.descendants(matching: .any)["wardrobe.editor.save"].click()
        XCTAssertTrue(app.staticTexts["已编辑的外套"].waitForExistence(timeout: 3))

        app.launchEnvironment.removeValue(forKey: "WARDROBE_UI_TEST_SEED_CLOTHING")
        app.launchEnvironment["WARDROBE_UI_TEST_SELECT_CLOTHING"] = "00000000-0000-0000-0000-000000000404"
        app.terminate()
        app.launch()
        let persistedCard = app.descendants(matching: .any)["wardrobe.item.00000000-0000-0000-0000-000000000404"]
        XCTAssertTrue(persistedCard.waitForExistence(timeout: 10))
        let archive = app.buttons["wardrobe.detail.archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.click()
        XCTAssertFalse(persistedCard.waitForExistence(timeout: 2))
    }
}
