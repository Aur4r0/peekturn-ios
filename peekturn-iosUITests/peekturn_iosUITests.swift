import XCTest

final class peekturn_iosUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyLibraryIsVisibleOnLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Import an original EPUB to begin reading."].exists)
    }
}
