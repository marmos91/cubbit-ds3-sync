import XCTest
@testable import DS3Lib

final class IPCCommandTests: XCTestCase {

    func test_refreshEnumeration_encodesParentKey() throws {
        let driveId = UUID()
        let cmd = IPCCommand.refreshEnumeration(driveId: driveId, parentKey: "Personal/Images/")
        let data = try JSONEncoder().encode(cmd)
        let decoded = try JSONDecoder().decode(IPCCommand.self, from: data)
        guard case .refreshEnumeration(let id, let key) = decoded else {
            XCTFail("Wrong case after decode"); return
        }
        XCTAssertEqual(id, driveId)
        XCTAssertEqual(key, "Personal/Images/")
    }

    func test_refreshEnumeration_decodesLegacyPayloadWithoutParentKey() throws {
        // Backwards compatibility: old Share extension builds may post commands without parentKey
        let driveId = UUID()
        let legacyJSON = #"{"refreshEnumeration":{"driveId":"\#(driveId.uuidString)"}}"#
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(IPCCommand.self, from: data)
        guard case .refreshEnumeration(let id, let key) = decoded else {
            XCTFail("Wrong case after decode"); return
        }
        XCTAssertEqual(id, driveId)
        XCTAssertNil(key)
    }
}
