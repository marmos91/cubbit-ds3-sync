import XCTest
@testable import DS3Lib

// MARK: - Mock

final class MockLifecycleService: LifecycleService, @unchecked Sendable {
    var isAutoLaunchEnabled: Bool
    var setAutoLaunchCalls: [Bool] = []

    init(isAutoLaunchEnabled: Bool = false) {
        self.isAutoLaunchEnabled = isAutoLaunchEnabled
    }

    func setAutoLaunch(_ enabled: Bool) throws {
        setAutoLaunchCalls.append(enabled)
        isAutoLaunchEnabled = enabled
    }
}

// MARK: - Tests

final class LifecycleServiceTests: XCTestCase {

    // MARK: - Factory

    func testDefaultFactoryReturnsNonNil() {
        let service = makeDefaultLifecycleService()
        XCTAssertNotNil(service)
    }

    // MARK: - macOS implementation

    #if os(macOS)
    func testMacOSIsAutoLaunchEnabledReturnsBool() {
        let service = MacOSLifecycleService()
        // Just verify it returns without crashing -- actual value depends on system state
        _ = service.isAutoLaunchEnabled
    }
    #endif

    // MARK: - Mock conformance

    func testMockSetAutoLaunchTracksCalls() throws {
        let mock = MockLifecycleService()
        XCTAssertFalse(mock.isAutoLaunchEnabled)

        try mock.setAutoLaunch(true)
        XCTAssertEqual(mock.setAutoLaunchCalls, [true])
        XCTAssertTrue(mock.isAutoLaunchEnabled)

        try mock.setAutoLaunch(false)
        XCTAssertEqual(mock.setAutoLaunchCalls, [true, false])
        XCTAssertFalse(mock.isAutoLaunchEnabled)
    }
}
