import XCTest
@testable import DS3Lib

final class AuthRequestTests: XCTestCase {
    // MARK: - DS3ChallengeRequest encoding

    func testChallengeRequestWithoutTenantEncodesEmailOnly() throws {
        let request = DS3ChallengeRequest(email: "test@cubbit.io")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["email"] as? String, "test@cubbit.io")
        XCTAssertNil(json["tenant_id"], "tenant_id should not appear when tenantId is nil")
    }

    func testChallengeRequestWithTenantEncodesBothFields() throws {
        let request = DS3ChallengeRequest(email: "test@cubbit.io", tenantId: "neonswarm")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["email"] as? String, "test@cubbit.io")
        XCTAssertEqual(json["tenant_id"] as? String, "neonswarm")
    }

    // MARK: - DS3LoginRequest encoding (uses .convertToSnakeCase)

    func testLoginRequestWithTenantEncodesCorrectly() throws {
        let request = DS3LoginRequest(
            email: "test@cubbit.io",
            signedChallenge: "abc123",
            tfaCode: nil,
            tenantId: "neonswarm"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["email"] as? String, "test@cubbit.io")
        XCTAssertEqual(json["signed_challenge"] as? String, "abc123")
        XCTAssertNil(json["tfa_code"])
        XCTAssertEqual(json["tenant_id"] as? String, "neonswarm")
    }

    func testLoginRequestWithoutTenantOmitsTenantId() throws {
        let request = DS3LoginRequest(
            email: "test@cubbit.io",
            signedChallenge: "abc123",
            tfaCode: nil,
            tenantId: nil
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["email"] as? String, "test@cubbit.io")
        XCTAssertEqual(json["signed_challenge"] as? String, "abc123")
        XCTAssertNil(json["tfa_code"])
        XCTAssertNil(json["tenant_id"], "tenant_id should not appear when tenantId is nil")
    }

    func testLoginRequestWithAllFieldsPopulated() throws {
        let request = DS3LoginRequest(
            email: "test@cubbit.io",
            signedChallenge: "abc123",
            tfaCode: "654321",
            tenantId: "neonswarm"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["email"] as? String, "test@cubbit.io")
        XCTAssertEqual(json["signed_challenge"] as? String, "abc123")
        XCTAssertEqual(json["tfa_code"] as? String, "654321")
        XCTAssertEqual(json["tenant_id"] as? String, "neonswarm")
    }
}
