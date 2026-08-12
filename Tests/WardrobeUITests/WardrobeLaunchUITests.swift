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
            app.terminate()
            if FileManager.default.fileExists(atPath: isolatedStorageRoot.path) {
                try FileManager.default.removeItem(at: isolatedStorageRoot)
            }
        }
        app.launch()
        ensureWindow(app)

        for route in ["wardrobe", "person", "outfits", "generationHistory", "settings", "tryOn"] {
            let sidebarItem = app.descendants(matching: .any)
                .matching(identifier: "sidebar.route.\(route)")
                .firstMatch
            XCTAssertTrue(sidebarItem.waitForExistence(timeout: 2))
            sidebarItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

            if route == "wardrobe" {
                XCTAssertTrue(app.staticTexts["我的衣橱"].waitForExistence(timeout: 2))
            } else if route == "person" {
                XCTAssertTrue(app.staticTexts["我的形象"].waitForExistence(timeout: 3))
            } else if route == "tryOn" {
                XCTAssertTrue(app.staticTexts["AI 试衣间"].waitForExistence(timeout: 3))
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
            app.terminate()
            if FileManager.default.fileExists(atPath: isolatedStorageRoot.path) {
                try FileManager.default.removeItem(at: isolatedStorageRoot)
            }
        }
        app.launch()
        ensureWindow(app)

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
        ensureWindow(app)
        let persistedCard = app.descendants(matching: .any)["wardrobe.item.00000000-0000-0000-0000-000000000404"]
        XCTAssertTrue(persistedCard.waitForExistence(timeout: 10))
        let archive = app.buttons["wardrobe.detail.archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.click()
        XCTAssertFalse(persistedCard.waitForExistence(timeout: 2))
    }

    func testInjectedPersonCanSetDefaultAndPersistEditedName() {
        let app = XCUIApplication()
        let isolatedStorageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeUIPersonFlow-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment["WARDROBE_STORAGE_ROOT_OVERRIDE"] = isolatedStorageRoot.path
        app.launchEnvironment["WARDROBE_UI_TEST_SEED_PERSON"] = "1"
        app.launchEnvironment["WARDROBE_UI_TEST_SELECT_PERSON"] = "00000000-0000-0000-0000-000000000505"
        addTeardownBlock {
            app.terminate()
            if FileManager.default.fileExists(atPath: isolatedStorageRoot.path) {
                try FileManager.default.removeItem(at: isolatedStorageRoot)
            }
        }
        app.launch()
        ensureWindow(app)
        app.descendants(matching: .any)["sidebar.route.person"].click()
        let profile = app.descendants(matching: .any).matching(identifier: "person.profile.00000000-0000-0000-0000-000000000505").firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        let makeDefault = app.buttons["person.detail.default"]
        XCTAssertTrue(makeDefault.waitForExistence(timeout: 2)); makeDefault.click()
        app.buttons["person.detail.edit"].click()
        let name = app.descendants(matching: .any)["person.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("已编辑人物")
        app.descendants(matching: .any)["person.editor.save"].click()
        XCTAssertTrue(app.staticTexts["已编辑人物"].waitForExistence(timeout: 3))

        app.launchEnvironment.removeValue(forKey: "WARDROBE_UI_TEST_SEED_PERSON")
        app.launchEnvironment["WARDROBE_UI_TEST_SELECT_PERSON"] = "00000000-0000-0000-0000-000000000505"
        app.terminate(); app.launch(); ensureWindow(app)
        app.descendants(matching: .any)["sidebar.route.person"].click()
        XCTAssertTrue(app.staticTexts["已编辑人物"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["person.detail.default"].waitForExistence(timeout: 3))
    }

    func testTryOnFixtureBuildsOutfitAndShowsMockSuccess() {
        let app = XCUIApplication()
        let isolatedStorageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeUITryOnFlow-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment["WARDROBE_STORAGE_ROOT_OVERRIDE"] = isolatedStorageRoot.path
        app.launchEnvironment["WARDROBE_UI_TEST_SEED_TRYON"] = "1"
        app.launchEnvironment["WARDROBE_DEBUG_MOCK_GENERATION"] = "1"
        app.launchEnvironment["WARDROBE_UI_TEST_INITIAL_ROUTE"] = "tryOn"
        addTeardownBlock { app.terminate() }
        app.launch()
        ensureWindow(app)
        XCTAssertTrue(app.descendants(matching: .any)["tryon.person.canvas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["试衣测试人物"].waitForExistence(timeout: 2))
        let clothing = app.descendants(matching: .any)["tryon.clothing.00000000-0000-0000-0000-000000000721"]
        XCTAssertTrue(clothing.waitForExistence(timeout: 3))
        let add = app.descendants(matching: .any)["tryon.add.00000000-0000-0000-0000-000000000721"]
        XCTAssertTrue(add.waitForExistence(timeout: 3)); add.click()
        let generate = app.buttons["tryon.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 2)); XCTAssertTrue(generate.isEnabled)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any)["tryon.mock.result"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["试穿已完成"].exists)
    }

    func testExternalChatGPTFixturePreparesPackageAndImportsResult() {
        let app = XCUIApplication()
        let isolatedStorageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WardrobeUIExternalFlow-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment["WARDROBE_STORAGE_ROOT_OVERRIDE"] = isolatedStorageRoot.path
        app.launchEnvironment["WARDROBE_UI_TEST_SEED_TRYON"] = "1"
        app.launchEnvironment["WARDROBE_UI_TEST_EXTERNAL_RESULT"] = "1"
        app.launchEnvironment["WARDROBE_UI_TEST_INITIAL_ROUTE"] = "tryOn"
        addTeardownBlock { app.terminate() }
        app.launch(); ensureWindow(app)
        XCTAssertTrue(app.descendants(matching: .any)["tryon.person.canvas"].waitForExistence(timeout: 5))
        let add = app.descendants(matching: .any)["tryon.add.00000000-0000-0000-0000-000000000721"]
        XCTAssertTrue(add.waitForExistence(timeout: 3)); add.click()
        let generate = app.buttons["tryon.external.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 3)); XCTAssertTrue(generate.isEnabled)
        app.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["tryon.external.ready-sheet"].waitForExistence(timeout: 5))
        let importButton = app.buttons["tryon.external.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 3))
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["tryon.external.imported-result"].waitForExistence(timeout: 8))
    }

    private func ensureWindow(_ app: XCUIApplication) {
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 1) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 6))
    }
}
