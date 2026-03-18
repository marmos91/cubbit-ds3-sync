import XCTest
@testable import DS3Lib

// MARK: - Mock

final class MockSystemService: SystemService, @unchecked Sendable {
    var deviceName: String
    var clipboardHistory: [String] = []
    var revealedURLs: [URL] = []

    init(deviceName: String = "MockDevice") {
        self.deviceName = deviceName
    }

    func copyToClipboard(_ text: String) {
        clipboardHistory.append(text)
    }

    func revealInFileBrowser(url: URL) {
        revealedURLs.append(url)
    }
}

// MARK: - Tests

final class SystemServiceTests: XCTestCase {

    // MARK: - Factory

    func testDefaultFactoryReturnsNonNil() {
        let service = makeDefaultSystemService()
        XCTAssertNotNil(service)
    }

    // MARK: - macOS implementation

    #if os(macOS)
    func testMacOSDeviceNameIsNotEmpty() {
        let service = MacOSSystemService()
        XCTAssertFalse(service.deviceName.isEmpty, "deviceName should not be empty on macOS")
    }

    func testMacOSCopyToClipboardDoesNotCrash() {
        let service = MacOSSystemService()
        // Just invoke -- don't assert clipboard state (CI may not have pasteboard)
        service.copyToClipboard("test-clipboard-content")
    }
    #endif

    // MARK: - Mock conformance

    func testMockDeviceNameReadback() {
        let mock = MockSystemService(deviceName: "TestDevice")
        XCTAssertEqual(mock.deviceName, "TestDevice")
    }

    func testMockCopyToClipboardCaptures() {
        let mock = MockSystemService()
        mock.copyToClipboard("hello")
        mock.copyToClipboard("world")
        XCTAssertEqual(mock.clipboardHistory, ["hello", "world"])
    }

    func testMockRevealInFileBrowserCaptures() {
        let mock = MockSystemService()
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        mock.revealInFileBrowser(url: url)
        XCTAssertEqual(mock.revealedURLs, [url])
    }
}
